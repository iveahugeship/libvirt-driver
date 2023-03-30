# libvirt-driver

Just a script that you can use as a custom Giltab Runner driver.
Gitlab will use the script to create the VM from the base image
and to execute jobs there.

Read the libvirt-driver.sh for more information about script 
arguments or the base image building. 

# Example

To using libvirt-driver add this to your Gitlab Runner configuration:
```
[[runners]]
executor = "custom"
[runners.custom]
cleanup_args = ["cleanup"]
cleanup_exec = "/usr/lib/gitlab-runner/libvirt-driver.sh"
prepare_args = ["create", "-i", "<base_image>", "-c", "8"]
prepare_exec = "/usr/lib/gitlab-runner/libvirt-driver.sh"
run_args = ["run"]
run_exec = "/usr/lib/gitlab-runner/libvirt-driver.sh"
```
