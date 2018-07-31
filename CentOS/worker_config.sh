echo __ADMINPASS__ | sudo -S date
sudo sh -c "cat /tmp/hosts >> /etc/hosts"
sudo chmod g-w /var/log
sudo useradd -c "Slurm scheduler" slurm
sudo yum -y install munge
sudo yum -y install /tmp/slurm-17.11.8-1.el7.centos.x86_64.rpm /tmp/slurm-contribs-17.11.8-1.el7.centos.x86_64.rpm /tmp/slurm-example-configs-17.11.8-1.el7.centos.x86_64.rpm /tmp/slurm-libpmi-17.11.8-1.el7.centos.x86_64.rpm /tmp/slurm-pam_slurm-17.11.8-1.el7.centos.x86_64.rpm /tmp/slurm-slurmd-17.11.8-1.el7.centos.x86_64.rpm
sudo cp -f /tmp/munge.key /etc/munge/munge.key
sudo chown munge /etc/munge/munge.key
sudo chgrp munge /etc/munge/munge.key
sudo rm -f /tmp/munge.key
sudo systemctl daemon-reload
sudo systemctl enable munge
sudo systemctl start munge
sudo cp -f /tmp/slurm.conf /etc/slurm/slurm.conf
sudo chown slurm /etc/slurm/slurm.conf
sudo systemctl enable slurmd
sudo systemctl start  slurmd
sudo yum -y install openmpi
