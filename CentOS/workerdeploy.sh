#!/bin/bash
exec >& /tmp/install.log

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

cp /data/ssh/ssh* /etc/ssh
service sshd restart

cp /data/system/hosts /etc/hosts
chmod g-w /var/log
useradd -c "Slurm scheduler" slurm
yum -y install epel-release
yum -y install munge
yum -y install /data/system/RPMS/x86_64/slurm-17.11.8-1.el7.x86_64.rpm  /data/system/RPMS/x86_64/slurm-example-configs-17.11.8-1.el7.x86_64.rpm /data/system/RPMS/x86_64/slurm-libpmi-17.11.8-1.el7.x86_64.rpm /data/system/RPMS/x86_64/slurm-pam_slurm-17.11.8-1.el7.x86_64.rpm /data/system/RPMS/x86_64/slurm-slurmd-17.11.8-1.el7.x86_64.rpm
cp -f /data/system/munge.key /etc/munge/munge.key
ls -l /etc/munge/munge.key
systemctl daemon-reload
systemctl enable munge
systemctl start munge
cp -f /data/system/slurm.conf /etc/slurm/slurm.conf
ls -l /etc/slurm/slurm.conf
chown slurm /etc/slurm/slurm.conf
systemctl enable slurmd
systemctl start  slurmd
yum -y install openmpi
sed -i -- 's/azureuser ALL=(ALL) ALL/azureuser ALL=(ALL) NOPASSWD:ALL/g' /etc/sudoers.d/waagent
# Install OpenMPI
yum -y install openmpi3-devel
# Fix broken tmpfilesd
systemctl enable systemd-tmpfiles-setup
