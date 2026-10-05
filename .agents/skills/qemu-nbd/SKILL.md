---
name: qemu-nbd
description: Set up, reuse, inspect, and tear down this project's QEMU/NBD Gentoo install targets; recover encrypted mappings held by mounts in other namespaces.
---

# QEMU/NBD install targets

Read [the installation playbook](../../../installer/QEMU-NBD-INSTALL.md) before operating on a target. It is the canonical production installation path: use the real installer and its existing configuration, without mocks or special test modes.

## Identify and reuse the target

Establish the backing image, NBD device, partition, encrypted mapping, and mount root from live evidence. Inspect `lsblk`, `findmnt`, `cryptsetup status`, `/sys/block/nbd*/pid`, and the corresponding QEMU process arguments. Treat the playbook's `/dev/nbd0`, `cryptroot`, and `/mnt/gentoo` as defaults, not proof of identity.

Reuse the existing target when the user wants to continue or debug an install. Resume the requested phase rather than repeating disk setup, which formats the target. Create or erase an image only when the user's request authorizes a fresh target. Preserve mounted targets after installer failures so the phase can be resumed.

Before closing a mapping, verify its backing partition belongs to the identified NBD device. Before disconnecting or deleting an image, verify the QEMU attachment belongs to that image. Stop relevant builds only when requested or necessary within the authorized task, and verify they have stopped before teardown.

## Elevation and interaction

On this Omarchy host, read the installed `omarchy` skill's Privilege Escalation section when privileged work is needed. Use `sudo` in a visible terminal where the user can enter a password; use `pkexec` for agent-launched work without an interactive password terminal. Do not wrap commands that already handle elevation. Submit a bounded operation with explicit target checks, rather than requesting an unrestricted root shell. Execution approval and authentication still apply.

Keep passphrases out of files, logs, and command arguments. Use a terminal prompt; use a disposable passphrase only when the user has authorized one for the test target.

## Detach and recover

Use the playbook's ordinary detach procedure first. If unmounting succeeds locally but `cryptsetup close` reports a busy mapping, inspect other mount namespaces before retrying. Read [namespace recovery](references/namespace-recovery.md) for the procedure that worked on this host.

After successful unmounting, close the verified mapping, disconnect the verified NBD device, and wait for the QEMU image lock to release before reattaching, recreating, or deleting the image. Verify the mapping is absent, the NBD device has zero capacity/no active connection, and the identified mount roots are absent from the namespaces inspected. Remove only artifacts within the requested cleanup scope.

A repeated failure requires new evidence or a changed approach. Do not repeatedly run an unchanged cleanup script. Report the remaining holder or uncertainty and preserve the image when safe teardown cannot be established. Avoid lazy/forced unmounts, killing unrelated services, or unloading the NBD module as routine recovery.

Report which devices and images were affected and which installer phases actually completed. A successful dry run or partial package build does not establish end-to-end installation success.
