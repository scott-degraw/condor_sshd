#!/bin/bash

# Ensure we are in the directory containing this script (Shared FS fix)
cd "$(dirname "$0")"

# Generate host keys if not present
if [ ! -f ssh_host_rsa_key ]; then
    ssh-keygen -f ssh_host_rsa_key -N '' -t rsa
    ssh-keygen -f ssh_host_ecdsa_key -N '' -t ecdsa
    ssh-keygen -f ssh_host_ed25519_key -N '' -t ed25519
fi

# Get a random port
PORT=$(shuf -i 2000-65000 -n 1)

# Create SSHD config
cat <<EOF > sshd_config
Port $PORT
HostKey $(pwd)/ssh_host_rsa_key
HostKey $(pwd)/ssh_host_ecdsa_key
HostKey $(pwd)/ssh_host_ed25519_key
AuthorizedKeysFile $(pwd)/authorized_keys
PidFile $(pwd)/sshd.pid
LogLevel INFO
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# Move authorized keys into place
# mv ../key.pub authorized_keys (Shared FS: key.pub is in cwd)
ls -l key.pub
cp key.pub authorized_keys
chmod 600 authorized_keys

# Explicitly print user for easier parsing if needed in future
echo "User: $(whoami)"

# Start SSHD
echo "Starting SSHD on port $PORT"
/usr/sbin/sshd -e -f $(pwd)/sshd_config -D &
PID=$!

# Print connection info
echo "Connect with: ssh -p $PORT $(whoami)@$(hostname)"

# Wait for SSHD to exit
wait $PID
