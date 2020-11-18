#!/bin/bash
set -x
exec >& /tmp/install.log

# This should be removed and fixed
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/sysconfig/selinux

SLURMVERSION=20.02.6

yum -y install nfs-utils
systemctl enable rpcbind
systemctl start rpcbind

mkdir /data
bash -c 'echo -e "master:/data\t/data\tnfs\tintr\t0 0" >> /etc/fstab'
mount /data

# Rejig to provide NFS home directories
bash -c 'echo -e "/data/home /home none bind 0 0" >> /etc/fstab'
mount -a
setsebool -P use_nfs_home_dirs=on

rsync -a /data/system/ssh/* /etc/ssh/
service sshd restart

mkdir -p /root/.ssh
cat /data/system/authorized_keys > /root/.ssh/authorized_keys

chmod g-w /var/log
useradd -c "Slurm scheduler" slurm
yum -y install epel-release
yum -y install munge
yum -y install /data/system/RPMS/x86_64/slurm-${SLURMVERSION}-1.el7.x86_64.rpm  /data/system/RPMS/x86_64/slurm-example-configs-${SLURMVERSION}-1.el7.x86_64.rpm /data/system/RPMS/x86_64/slurm-libpmi-${SLURMVERSION}-1.el7.x86_64.rpm /data/system/RPMS/x86_64/slurm-pam_slurm-${SLURMVERSION}-1.el7.x86_64.rpm /data/system/RPMS/x86_64/slurm-slurmd-${SLURMVERSION}-1.el7.x86_64.rpm
install -m 600 -o munge -g munge /data/system/munge.key /etc/munge/munge.key
ls -l /etc/munge/munge.key
systemctl daemon-reload
systemctl enable munge
systemctl start munge
rm -f /etc/slurm/slurm.conf
ln -s /data/system/slurm.conf /etc/slurm/slurm.conf
systemctl enable slurmd
systemctl start  slurmd
# Install OpenMPI
yum -y install openmpi3-devel
# Fix broken tmpfilesd
systemctl enable systemd-tmpfiles-setup

# Make sudo passwordless for AAD Admins
echo '%aad_admins ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/aad_admins
