#!/bin/bash
set -euo pipefail

# Default values
REMOTE_HOST=""
BATCH_NAME=""
REQUESTED_PORT=""
CONNECT_FLAG=0
NEW_JOB=0

usage() {
    echo "Usage: $0 [options] <batch-name> <user@submission-node>"
    echo ""
    echo "Arguments:"
    echo "  <batch-name>          Unique name for the job (e.g., 'dev-session')"
    echo "  <user@submission-node> SSH login for submission node"
    echo ""
    echo "Options:"
    echo "  -p <PORT>   Specify the local port for the tunnel (default: random)"
    echo "  -c          Automatically connect when ready"
    echo "  -h          Show this help message"
    echo ""
    exit 1
}

# Parse arguments using getopts
while getopts "p:ch" opt; do
    case $opt in
        p)
            REQUESTED_PORT="$OPTARG"
            ;;
        c)
            CONNECT_FLAG=1
            ;;
        h)
            usage
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
    esac
done

# Shift off the options and arguments processing by getopts
shift $((OPTIND -1))

# Check for required positional arguments
if [ $# -ne 2 ]; then
    echo "Error: Missing required arguments."
    usage
fi

BATCH_NAME="$1"
REMOTE_HOST="$2"

# Detect Public Key
LOCAL_PUB_KEY=""
POSSIBLE_KEYS=(
    "$HOME/.ssh/id_ed25519.pub"
    "$HOME/.ssh/id_rsa.pub"
    "$HOME/.ssh/id_ecdsa.pub"
)

for key in "${POSSIBLE_KEYS[@]}"; do
    if [ -f "$key" ]; then
        LOCAL_PUB_KEY="$key"
        # echo "Found public key: $LOCAL_PUB_KEY"
        break
    fi
done

if [ -z "$LOCAL_PUB_KEY" ]; then
    echo "Error: No public key found in standard locations (~/.ssh/id_{ed25519,rsa,ecdsa}.pub)."
    echo "Please generate one with 'ssh-keygen -t ed25519' or provide one manually."
    exit 1
fi

# Check for job files
if [ ! -f "job.submit" ] || [ ! -f "entrypoint.sh" ]; then
    echo "Error: job.submit or entrypoint.sh not found in current directory."
    exit 1
fi

# Determine Remote Directory and Batch Logic
# Determine Remote Directory and Batch Logic
REMOTE_DIR="condor_ssh_job_${BATCH_NAME}"
echo "Using batch name: $BATCH_NAME"

# Check if job is already running
# We use condor_q to check for a running job with this batch name
echo "Checking for existing job..."
# Note: condor_q doesn't support -batch-name for filtering in older versions, using constraint is safer
# We use -af (without header options) to get just the values.
# If no jobs match, output will be empty, making the check reliable.
JOB_CHECK=$(ssh "$REMOTE_HOST" "condor_q -constraint 'JobBatchName == \"$BATCH_NAME\"' -af JobStatus ClusterId" 2>/dev/null || true)

# JobStatus: 1=Idle, 2=Running, etc.
if [[ -n "$JOB_CHECK" ]]; then
    echo "Found existing job: $JOB_CHECK"
    echo "Reconnecting to existing job..."
    # Skip submission, proceed to connection info extraction
else
    echo "No running job found. Starting new one..."
    NEW_JOB=1
fi

if [ "$NEW_JOB" == "1" ]; then
    # Create remote directory
    echo "Creating remote directory: $REMOTE_DIR on $REMOTE_HOST"
    ssh "$REMOTE_HOST" "mkdir -p $REMOTE_DIR"

    # Upload files
    echo "Uploading files..."
    scp job.submit entrypoint.sh "$REMOTE_HOST:$REMOTE_DIR/"
    scp "$LOCAL_PUB_KEY" "$REMOTE_HOST:$REMOTE_DIR/key.pub"

    # Submit job
    echo "Submitting job..."
    # Remove job files if they exist so 
    SUBMIT_CMD="cd $REMOTE_DIR && { rm job.{err,out,log} || true; } && condor_submit job.submit -batch-name $BATCH_NAME"
    ssh "$REMOTE_HOST" "$SUBMIT_CMD"
fi

echo "Waiting for job to be ready..."


# Wait for connection string and user info
while ! ssh "$REMOTE_HOST" "grep -m1 'Connect with: ssh' $REMOTE_DIR/job.out &>/dev/null"; do
    sleep 5
done

JOB_PORT="$(ssh $REMOTE_HOST "sed -n -E 's/.*Starting SSHD on port ([0-9]+).*/\1/p' $REMOTE_DIR/job.out 2>/dev/null" | head -n 1)"
JOB_USER="$(ssh $REMOTE_HOST "sed -n -E 's/.*Connect with: ssh -p [0-9]+ ([^@]+)@.*/\1/p' $REMOTE_DIR/job.out 2>/dev/null" | head -n 1)"

if [ -z "$JOB_PORT" ]; then
    echo "Error: Could not determine Job Port."
    exit 1
fi

if [ -z "$JOB_USER" ]; then
    echo "Warning: Could not determine Job User. Defaulting to 'whoami' output from job if possible, or local user."
    # Try one more way or just fallback
    JOB_USER=$(ssh "$REMOTE_HOST" "condor_q -constraint 'JobBatchName == \"$BATCH_NAME\"' -af Owner" | head -n 1)
fi

if [ -z "$JOB_USER" ]; then
    JOB_USER="$USER" # Fallback to local user
fi

CLUSTER_ID=$(ssh "$REMOTE_HOST" "condor_q -constraint 'JobBatchName == \"$BATCH_NAME\"' -af ClusterId" | head -n 1)

if [ -z "$CLUSTER_ID" ]; then
    echo "Error: Could not determine ClusterId."
    exit 1
fi

echo "Job ClusterId: $CLUSTER_ID"
echo "Job Port: $JOB_PORT"
echo "Job User: $JOB_USER"

# Check if we already have a remote tunnel running for this batch?
# For now, we'll just start a new one.

# Pick a random Traffic Port for the Submit Node
TRAFFIC_PORT=$(awk 'BEGIN{srand();print int(rand()*(60000-2000))+2000 }')
echo "Selected Traffic Port on Submit Node: $TRAFFIC_PORT"

# Use the same port locally for simplicity
if [ -n "$REQUESTED_PORT" ]; then
    LOCAL_PORT="$REQUESTED_PORT"
else
    LOCAL_PORT=$TRAFFIC_PORT
fi

# Check if local port is in use and kill valid process
if lsof -i :$LOCAL_PORT >/dev/null 2>&1; then
    echo "Port $LOCAL_PORT is in use. Killing process..."
    # Get PID of process using the port (ignoring our own script if somehow caught, but unlikely)
    # We use -t for terse output (PID only)
    PID_TO_KILL=$(lsof -t -i :$LOCAL_PORT)
    if [ -n "$PID_TO_KILL" ]; then
        kill $PID_TO_KILL || kill -9 $PID_TO_KILL
        echo "Killed process $PID_TO_KILL"
        sleep 1
    fi
fi

echo "Setting up explicit double tunnel..."
echo "1. Remote Tunnel: Submit Node:$TRAFFIC_PORT -> via condor_ssh_to_job -> Job:$JOB_PORT"
echo "2. Local Tunnel:  Localhost:$LOCAL_PORT -> via ssh -> Submit Node:$TRAFFIC_PORT"

REMOTE_TUNNEL_CMD="condor_ssh_to_job -auto-retry $CLUSTER_ID -NfL localhost:$TRAFFIC_PORT:localhost:$JOB_PORT"
echo "Starting remote tunnel..."
ssh -f "$REMOTE_HOST" "$REMOTE_TUNNEL_CMD" &

# Give it a moment
sleep 3

# Start Local Tunnel
# Forward local port to traffic port on remote
echo "Starting local tunnel..."
ssh -NfL "localhost:$LOCAL_PORT:localhost:$TRAFFIC_PORT" "$REMOTE_HOST"
sleep 2

SSH_CMD="ssh -p $LOCAL_PORT -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $JOB_USER@localhost"

echo ""
echo "Job is ready."
echo "---------------------------------------------------"
echo "Connection command (Double Tunnel):"
echo "$SSH_CMD"
echo "---------------------------------------------------"

# Generate VSCode Config
CONFIG_HOST="condor-job-$BATCH_NAME"

echo "For VSCode / Antigravity, add this to your ~/.ssh/config:"
echo "Host $CONFIG_HOST"
echo "    HostName localhost"
echo "    Port $LOCAL_PORT"
echo "    User $JOB_USER"
echo "    UserKnownHostsFile /dev/null"
echo "    StrictHostKeyChecking no"
echo ""

# Optional: Automatic connection
if [ "$CONNECT_FLAG" -eq 1 ]; then
    echo "Connecting..."
    eval $SSH_CMD
fi
