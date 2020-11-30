#!/bin/bash
set -x
exec >& /root/install.log

# This should be removed and fixed
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# Sort EPEL out early
yum -y install epel-release

# Just discover if we have an nvidia card, and update and install a driver if so
if lspci|grep -i nvidia;then
  yum -y install dkms kernel-devel
  CUDA_REPO_PKG=cuda-repo-rhel7-10.2.89-1.x86_64.rpm
  yum -y install --nogpg http://developer.download.nvidia.com/compute/cuda/repos/rhel7/x86_64/${CUDA_REPO_PKG}
  yum -y upgrade --exclude=WALinuxAgent
  yum -y install cuda
fi

SLURMVERSION=20.02.6

yum -y install nfs-utils
systemctl enable rpcbind
systemctl start rpcbind

mkdir /data
bash -c 'echo -e "master:/data\t/data\tnfs\tdefaults\t0 0" >> /etc/fstab'
mount /data

# Rejig to provide NFS home directories
bash -c 'echo -e "master:/data/home\t/home\tnfs\tdefaults\t0 0" >> /etc/fstab'
mount -a
setsebool -P use_nfs_home_dirs=on

rsync -a /data/system/ssh/* /etc/ssh/
service sshd restart

mkdir -p /root/.ssh
cat /data/system/authorized_keys > /root/.ssh/authorized_keys

chmod g-w /var/log
useradd -c "Slurm scheduler" slurm
yum -y install munge
yum -y install /data/system/RPMS/x86_64/slurm-${SLURMVERSION}-1.el7.x86_64.rpm  /data/system/RPMS/x86_64/slurm-example-configs-${SLURMVERSION}-1.el7.x86_64.rpm /data/system/RPMS/x86_64/slurm-libpmi-${SLURMVERSION}-1.el7.x86_64.rpm /data/system/RPMS/x86_64/slurm-pam_slurm-${SLURMVERSION}-1.el7.x86_64.rpm /data/system/RPMS/x86_64/slurm-slurmd-${SLURMVERSION}-1.el7.x86_64.rpm
install -m 400 -o munge -g munge /data/system/munge.key /etc/munge/munge.key
md5sum /data/system/munge.key /etc/munge/munge.key
systemctl daemon-reload
systemctl enable munge
systemctl start munge
rm -f /etc/slurm/slurm.conf
ln -s /data/system/slurm.conf /etc/slurm/slurm.conf
ln -s /data/system/gres.conf /etc/slurm/gres.conf
ln -s /data/system/cgroup.conf /etc/slurm/cgroup.conf
ln -s /data/system/cgroup_allowed.conf /etc/slurm/cgroup_allowed.conf
systemctl enable slurmd

# Install OpenMPI
yum -y install openmpi3-devel
# Fix broken tmpfilesd
systemctl enable systemd-tmpfiles-setup

# Make sudo passwordless for AAD Admins
echo '%aad_admins ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/aad_admins
cat /data/system/hosts > /etc/hosts
ln -sf /data/system/aadpasswd /etc/aadpasswd

# If we've got nvidia, schedule a reboot, else start slurmd
if lspci|grep -i nvidia;then
  shutdown -r +1
else
  systemctl start  slurmd
fi
