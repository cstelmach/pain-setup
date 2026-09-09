# PPP Map Setup
This repository contains the Docker Compose configuration for the entire PPP Map project.
It allows versioning the orchestration setup separately from individual services.

## Usage

### PowerShell (Windows)
```powershell
# Start all services
.\setup.ps1 -Up

# Stop all services
.\setup.ps1 -Down

# Build services
.\setup.ps1 -Build
```

### Manual (any OS)
```bash
# Copy compose file to workspace root
cp docker-compose.yml ../

# Then run from workspace root
docker-compose up -d
docker-compose down
```

## Services
- **pain-server**: Node.js/TypeScript API server with Python 3.11 support
- **pain-db**: PostgreSQL 16 database

## Requirements
- Docker and Docker Compose installed
- Services in sibling folders: `../pain-server`, `../pain-db`

## Export projection interactions

With the local site running, double-click `export-interactions.command` on macOS or
`export-interactions.cmd` on Windows. The scripts find the workspace Compose file relative to
their own location, so they also work when launched outside this directory.

The resulting timestamped ZIP appears in `interaction-exports/`. Copy it to a USB stick for
analysis. It contains a streaming CSV export, a summary JSON, and a data dictionary from one
read-only database snapshot. This requires the interaction-events migration to have been applied.
It exports only the new interaction table, without survey answers, written text, visitor locations,
IP addresses, or raw server logs. Pseudonymous interaction histories should remain team-private.
Repeated exports overlap; the dictionary explains deduplication. Exporting does not clear the data.

For a different output or workspace location:

```bash
./export-interactions.sh /path/to/output /path/to/workspace/docker-compose.yml
```

```powershell
.\export-interactions.ps1 -OutputDirectory 'D:\exports' -ComposeFile 'C:\pain\docker-compose.yml'
```

Docker Desktop must be running. Bash also needs `zip`; PowerShell uses its built-in ZIP support.
If export fails, no completed ZIP is announced, and that invocation's small staging folder retains
the diagnostics. Do not use the legacy raw-log exporter for the privacy-limited interaction export.

Developer check: `python3 verify-interaction-export.py` runs against a fake Docker executable,
including paths with spaces and a simulated database failure. It never contacts the installed stack.
