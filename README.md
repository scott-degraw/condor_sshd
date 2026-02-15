# Condor SSHD Wrapper

This repository provides a set of scripts to launch a lightweight SSH server (SSHD) inside an HTCondor job and establish a secure, double-tunneled connection to it from your local machine.

## Features

- **Automated Job Submission**: Checks for existing jobs with a specific batch name or submits a new one.
- **Double Tunneling**: 
    1.  **Remote Tunnel**: From the submission node to the worker node (via `condor_ssh_to_job`).
    2.  **Local Tunnel**: From your local machine to the submission node (via regular SSH).
- **VSCode Ready**: Outputs a configuration snippet for easy integration with VSCode Remote SSH.
- **Persistence**: Reconnects to existing sessions if the job is still running.

## Prerequisites

- Local machine: SSH client, `bash`.
- Submission Node: `condor_submit`, `condor_q`, `condor_ssh_to_job` available in PATH.
- **Shared Filesystem**: The submission node and worker nodes must share a filesystem (required for file transfer and log monitoring in this version).

## Usage

### 1. Clone the Repository

```bash
git clone https://github.com/scott-degraw/condor_sshd.git
cd condor_sshd
```

### 2. Connect to a Job

Run the `connect.sh` script with a unique batch name and your submission node login:

```bash
./connect.sh <batch-name> <user@submission-node>
```

**Example:**
```bash
./connect.sh my-dev-session scott@submit.example.com
```

### Options

| Flag       | Description                                      |
| :--------- | :----------------------------------------------- |
| `-p <PORT>`| Specify the local port for the tunnel (default: random) |
| `-c`       | Automatically connect via SSH when ready         |
| `-h`       | Show help message                                |

### Example with Options

Connect to `submit.example.com`, use local port `8888`, and auto-connect:

```bash
./connect.sh -p 8888 -c my-dev-session scott@submit.example.com
```

## How it Works

1.  **Job Check**: The script checks if a Condor job with the `JobBatchName` matches your input.
2.  **Submission**:
    - If no job runs, it creates a directory `condor_ssh_job_<batch-name>` on the remote host.
    - Uploads `job.submit`, `entrypoint.sh`, and your local public key (`~/.ssh/id_*.pub`).
    - Submits the job.
3.  **Startup**: The job runs `entrypoint.sh`, which generates host keys, starts `sshd` on a random port, and waits.
4.  **Tunnels**:
    - `connect.sh` waits for the job to print the port number.
    - Establishes a tunnel from the submit node to the job.
    - Establishes a tunnel from your localhost to the submit node.
5.  **Connection**: Outputs the SSH command to connect.

## Troubleshooting

-   **"No public key found"**: Ensure you have an SSH key pair (`ssh-keygen -t ed25519`).
-   **Shared Filesystem**: This script currently relies on `should_transfer_files = NO`, meaning the submission node and worker nodes must see the same files.
