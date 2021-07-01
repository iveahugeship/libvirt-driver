#!/usr/bin/env bash
#
# libvirt-driver - tool for executing GitLab jobs into libvirt VM.
# It just creates VM from base image and connects into by ssh.
#
# Dependencies:
# - libvirt-daemon
# - libvirt-clients
# - qemu-kvm
# - virtinst
#
# Your base image minimal requires:
# - installed git, git-lfs, gitlab-runner, openssh-server
# - gitlab-runner user with /bin/bash shell and /var/gitlab-runner
#   home directory owned by him.
# - configured openssh by connecting with keys pair. The private key
#   need to be located to host machine in /root/.ssh/id_rsa and public key
#   to guest machine (base image) in /var/gitlab-runner/.ssh/authorized_keys.
# - configured network interfaces by dhcp and autostart.
#
# Variables:
# IMAGES_PATH - path with base images.
# VM_ID - name of created VMs. Must be unique.
# VM_IMAGES - name of created for created VMs images. Must be unique.

set -eo pipefail

# Job context variables. 
readonly IMAGES_PATH="/var/lib/libvirt/images"
readonly VM_ID="runner-${CUSTOM_ENV_CI_PROJECT_NAME}-${CUSTOM_ENV_CI_JOB_ID}"
readonly VM_IMAGE="${VM_IMAGES_PATH}/${VM_ID}.qcow2"

# Script context variables.
readonly APP_NAME="${0##*/}"

# 'create' command options.
vm_image_name=""
vm_vcpus=4
vm_ram=4096
vm_network="default"


# Show a message.
# $1: message string.
print_msg() {
  local msg="${1}"
  printf '%s\n' "${msg}"
}

# Show an ERROR message then exit with status.
# $1: message string.
# $2: exit code number (with 0 does not exit).
print_error() {
  local msg="${1}"
  local error=${2}
  print_msg "ERROR: ${msg}" >&2
  exit "${error}"
}

# Trap any error, and mark it as a system failure.
trap 'print_mst "Critical Error" "${SYSTEM_FAILURE_EXIT_CODE}"' ERR

# GitLab collapsible sections start.
# More: https://docs.gitlab.com/ee/ci/jobs/#custom-collapsible-sections
# $1: section name.
# $2: title name.
print_section_start() {
  local section title
  section="${1}"
  title="${2}"

  print_msg "\e[0Ksection_start:$(date +%s):${section}\r\e[0K${title}\n"
}

# GitLab collapsible sections end.
# More: https://docs.gitlab.com/ee/ci/jobs/#custom-collapsible-sections
# $1: section name.
print_section_end() {
  local section="${1}"

  print_msg "\e[0Ksection_end:$(date +%s):${section}\r\e[0K\n"
}

# Show script usage message.
print_usage() {
  IFS='' read -r -d '' usagetext <<ENDUSAGETEXT || true
usage: ${APP_NAME} <command> [options]
  commands:
    create            Create VM in the job context.
    run               Run VM to job processing.
    cleanup           Destroy VM int the job context.

  create options:
    -i <file>         Filename of base image located in ${IMAGES_PATH}.
                      Example: '${APP_NAME} -i archlinux.qcow2'.
    -c <number>       VCPUs number.
                      Default: '${vm_vcpus}'.
    -r <number>       RAM volume.
                      Default: '${vm_ram}'.
    -n <name>         Network label.
                      Default: '${vm_network}'.

  global options:
    --help            Print this message.
ENDUSAGETEXT
  print_msg "${usagetext}"
}

# Return the ip of current processing job VM.
get_vm_ip() {
  virsh -q domifaddr "$VM_ID" | awk '{print $4; exit}' | sed -E 's|/([0-9]+)?$||'
}

# Replacement for 'sleep' command, because 'sleep'
# is an external command and not a bash built-in. 
# $1: number of seconds to sleep.
_sleep() {
  read -rt "${1}" <> <(:) || :
}

install_vm() {
  print_section_start "install_vm" "Installing VM"

  # Create image.
  qemu-img create \
    -f qcow2 \
    -F qcow2 \
    -b "${IMAGES_PATH}/${vm_image_name}" \
    "${VM_IMAGE}"

  # Create VM from image.
  virt-install \
    --name "${VM_ID}" \
    --disk "${VM_IMAGE}" \
    --import \
    --vcpus=${vm_vcpus} \
    --ram=${vm_ram} \
    --network ${vm_network} \
    --graphics none \
    --noautoconsole

  print_section_end "install_vm"
}

init_vm() {
  print_section_start "init_vm" "Initializing VM"

  wait_ip
  wait_ssh

  print_section_end "init_vm"
}

wait_ip() {
  # Wait for VM ip.
  local ip
  for i in $(seq 1 120); do
    ip=$(get_vm_ip)

    if [ -n "${ip}" ]; then
      printmsg "VM got ip: ${ip}"
      break
    fi

    if [ "$i" == "120" ]; then
      # Inform GitLab Runner that this is a system failure, so it
      # should be retried.
      print_error \
        "Waited 120 seconds for VM to start, exiting..." \
        "${SYSTEM_FAILURE_EXIT_CODE}"
    fi

    _sleep 1
  done
}

wait_ssh() {
  # Wait for ssh to become available.
  # shellcheck disable=SC2155
  local ip=$(get_vm_ip)
  for i in $(seq 1 60); do
    if ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no gitlab-runner@"${ip}" >/dev/null 2>/dev/null; then
      printf '%s\n' "VM accessible by ssh"
      break
    fi

    if [ "$i" == "60" ]; then
      # Inform GitLab Runner that this is a system failure, so it
      # should be retried.
      print_error \
        "Waited 60 seconds for sshd to start, exiting..."
        "${SYSTEM_FAILURE_EXIT_CODE}"
    fi

    _sleep 1
  done
}

create() {
  while getopts ':i:crn' arg; do
    case "${arg}" in
      i) vm_image_name="${OPTARG}" ;;
      c) vm_vcpus="${OPTARG}" ;;
      r) vm_ram="${OPTARG}" ;;
      n) vm_network="${OPTARG}" ;;
      *)
        print_usage
        print_error "Invalid Argument '${OPTARG}'"
        ;;
    esac
  done

  install_vm
  init_vm
}

run() {
  print_section_start "run_step_script" "Run step script"

  # shellcheck disable=SC2155
  local ip=$(get_vm_ip)
  # shellcheck disable=SC2181
  ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no gitlab-runner@"${ip}" /bin/bash < "${1}"
  if [ $? -ne 0 ]; then
    # Exit using the variable, to make the build as failure in GitLab CI.
    print_error "Building process error" "${BUILD_FAILURE_EXIT_CODE}"
  fi
  
  print_section_end "run_step_script"
}

cleanup() {
  # Destroy VM.
  virsh shutdown "$VM_ID"
  
  # Undefine VM.
  virsh undefine "$VM_ID"
  
  # Delete VM disk.
  if [ -f "$VM_IMAGE" ]; then
    rm "$VM_IMAGE"
  fi
}

main() {
  case "$1" in
    --help)
      print_usage
      ;;
    create) 
      shift
      create "$@"
      ;;
    run)
      shift
      run "$@"
      ;;
    cleanup)
      shift
      cleanup "$@"
      ;;
    *)
      print_usage
      print_error "Invalid Argument '${1}'" 1
      ;;
  esac
  shift
}


main "$@"

