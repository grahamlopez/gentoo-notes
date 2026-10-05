# Recover a target held in other mount namespaces

## Observed failure

During this project's installer testing, ordinary host unmounts left encrypted mappings busy. Copies of the target mounts existed in service mount namespaces; the final copies were found in Avahi's namespace. Recursively unmounting the verified target root once in each namespace containing it allowed the mappings to close and NBD devices to disconnect.

This can affect manual installations too. Shared mount propagation can copy mounts into service namespaces. Agent execution adds complexity, but `pkexec` alone was not established as the cause. Do not assume a particular service, PID, namespace ID, or test filename will recur.

## Inspect before mutation

1. Verify the image/QEMU process/NBD/mapping relationship and record the target root.
2. Confirm relevant installer and build processes have stopped.
3. Inspect `/proc/[0-9]*/mountinfo` as root for the exact mount root and its descendants. Deduplicate by `/proc/PID/ns/mnt`; ordinary host `findmnt` shows only the caller's namespace.
4. Inspect each matching namespace's mount tree and sources before unmounting. Require the expected verified target filesystem at the root; unexpected sources require investigation.

## Successful recovery pattern

The following Bash example is a procedure to adapt and review, not an automatic cleanup command. Run it as a bounded privileged operation only after the checks above. Set `target_root` to the verified target mount root. The example assumes a simple absolute path without whitespace or mountinfo escapes, as used by this playbook.

```bash
set -euo pipefail
target_root=/mnt/gentoo
[[ $target_root == /mnt/gentoo ]] || exit 1

declare -A seen=()
for info in /proc/[0-9]*/mountinfo; do
  [[ -r $info ]] || continue
  # Field 5 is the mountpoint; include descendants when the root is absent.
  awk -v root="$target_root" '
    $5 == root || index($5, root "/") == 1 { found=1 }
    END { exit !found }
  ' "$info" 2>/dev/null || continue
  pid=${info#/proc/}
  pid=${pid%/mountinfo}
  ns=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null) || continue
  [[ ${seen[$ns]+present} ]] && continue
  seen[$ns]=1
  # Review this tree and verify its sources before executing the unmount.
  nsenter -t "$pid" -m -- findmnt -R "$target_root"
  nsenter -t "$pid" -m -- umount --recursive "$target_root"
done
```

The root-path guard must be deliberately updated for a different verified target. If the root itself is no longer mounted but descendants remain, inspect those mountpoints and recursively unmount the verified remaining subtrees; do not broaden the operation to unrelated paths. If a process disappears or a command fails, reassess namespace state instead of suppressing every error. Rescan after recovery because processes and namespaces can change.

Only after all target mount copies have been removed:

- Recheck the mapping's backing partition, then `cryptsetup close` that mapping.
- Recheck the attachment's image, then `qemu-nbd --disconnect` that device.
- Wait for the device's connection PID to disappear and capacity to become zero.
- Use a bounded retry of `qemu-img info "$IMAGE"` (the playbook uses 50 attempts at 0.1 seconds) to confirm the image lock was released. Do not bypass locking with force-sharing options.
- Preserve the image unless deletion was requested. If cleanup was requested, remove only the verified image and associated test artifacts.

Do not disconnect underneath an open encrypted mapping or mounted filesystem. A busy mapping after this procedure calls for fresh inspection of namespaces and holders, not another identical teardown attempt.
