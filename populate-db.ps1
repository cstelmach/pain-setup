# File attribution
# edited by Christian Stelmach (chrisp.stel@gmail.com), GitHub: @cstelmach
# changes: +5 / -2 lines (excluding attribution)
# baseline: 0347e040bc74 (development before PR #6)
# 
param(
    [switch]$Init,
    [switch]$Fill,
    [string]$FillTarget,
    [switch]$Test,
    [switch]$Reset,
    [switch]$Connect,
    [string]$Clear,
    [string]$ExportMetrics
)

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$composeFile = Join-Path $workspaceRoot "docker-compose.yml"

if (-not (Test-Path $composeFile)) {
    Write-Error "Compose file not found at $composeFile. Run .\setup.ps1 -Up first to generate it."
    exit 1
}

$containerId = docker compose -f $composeFile ps -q pain-db
Write-Host "Found pain-db container with ID: $containerId"

if (-not $containerId) {
    Write-Error "No running pain-db container found. Start the stack first with .\setup.ps1 -Up"
    exit 1
}

# load config variables from db-config.env
$configFile = Join-Path $PSScriptRoot 'db-config.env'
if (-not (Test-Path $configFile)) {
    throw "Missing DB config: $configFile"
}
# load config file and set variables
Get-Content $configFile | ForEach-Object {
    if ($_ -match '^\s*([^=]+)\s*=\s*(.*)\s*$') {
        Set-Variable -Name $matches[1] -Value $matches[2]
    }
}

if ($Init) {
    function Create-Table {
        param ($TableName, $Additions)

        docker exec -it $containerId psql -U postgres -d pain_db -c "CREATE TABLE $TableName ($COL_ID SERIAL PRIMARY KEY $Additions);"
    }
    function Create-Data-Table {
        param ($TableName, $Additions)

        Create-Table $TableName ", $COL_AGGR_ID INTEGER REFERENCES $TableName($COL_ID), $COL_VALUE FLOAT NOT NULL, $COL_CATEGORY TEXT NOT NULL $Additions"
    }
    function Create-Metrics-Table {
        param ($TableName, $Additions)

        Create-Table $TableName ", $COL_DT $TYPE_DT NOT NULL, $COL_USER_ID INTEGER REFERENCES $TNM_USERS($COL_ID) $Additions"
    }
    function Create-Enum {
        param ($EnumName, $EnumValues)

        docker exec -it $containerId psql -U postgres -d pain_db -c "CREATE TYPE ${EnumName} AS ENUM (${EnumValues});"
    }
    Write-Host "Initializing database schema..."
    # create Emotional, Environment, Physical & Socioeconomic Layer Table
    Create-Data-Table $TN_EMO ", $COL_COUNTRY TEXT NOT NULL, $COL_WORD TEXT NOT NULL"
    Create-Data-Table $TN_ENV ", $COL_LAT FLOAT NOT NULL, $COL_LNG FLOAT NOT NULL"
    Create-Data-Table $TN_PHYS ", $COL_LAT FLOAT NOT NULL, $COL_LNG FLOAT NOT NULL"
    Create-Data-Table $TN_SOCIOECO ", $COL_COUNTRY TEXT NOT NULL"
    Create-Data-Table $TN_EXPERIMENTAL ", $COL_LAT FLOAT NOT NULL, $COL_LNG FLOAT NOT NULL"
    # create enums for metrics tables
    Create-Enum ${TYPE_TOGGLE_KIND} ${VALUES_TYPE_TOGGLE_KIND}
    Create-Enum ${TYPE_TOGGLE_ELEM} "'${TN_EMO}', '${TN_ENV}', '${TN_PHYS}', '${TN_SOCIOECO}', '${TN_EXPERIMENTAL}', ${VALUES_TYPE_TOGGLE_ELEM_ADD_LAYERS}, ${VALUES_TYPE_TOGGLE_ELEM_PAIN}, ${VALUES_TYPE_TOGGLE_ELEM_TEMPORALITY}, ${VALUES_TYPE_TOGGLE_ELEM_RELATIONS}"
    Create-Enum ${TYPE_VIS_MODE} ${VALUES_TYPE_VIS_MODE}
    # create metrics tables
    Create-Table $TNM_USERS ", $COL_DT $TYPE_DT NOT NULL, $COL_USER_ID TEXT NOT NULL"
    Create-Metrics-Table $TNM_USER_COORDINATES ", $COL_LAT FLOAT NOT NULL, $COL_LNG FLOAT NOT NULL"
    Create-Metrics-Table $TNM_TOGGLE ", $COL_KIND TEXT NOT NULL, $COL_ELEM TEXT NOT NULL, $COL_ENABLED BOOL NOT NULL"
    Create-Metrics-Table $TNM_STEP ", $COL_STEP SMALLINT NOT NULL CHECK ($COL_STEP BETWEEN 0 AND $TYPE_STEP_MAX)"
    Create-Metrics-Table $TNM_VIS ", $COL_VIS_MODE ${TYPE_VIS_MODE} NOT NULL"
    Get-Content -Raw (Join-Path $PSScriptRoot 'migrations/20260909-interaction-events.sql') |
        docker exec -i $CONTAINER_ID psql -X -v ON_ERROR_STOP=1 -U postgres -d pain_db
    if ($LASTEXITCODE -ne 0) { throw 'Interaction schema initialization failed.' }

    Write-Host "Finished initializing!"
}
elseif ($Fill) {
    function Fill-Table {
        param ($TableName, $csvFile, $destFile)

        Write-Host "Filling $TableName with dummy data..."
        docker cp $csvFile "$($containerId):$destFile"
        # copy data from CSV into the table
        docker exec $containerId psql -U postgres -d pain_db -c "COPY $TableName FROM '$destFile' CSV HEADER;"
        # reset the sequence for the table's serial ID column
        docker exec $containerId psql -U postgres -d pain_db -c "SELECT setval(pg_get_serial_sequence('$TableName', '$COL_ID'), COALESCE(MAX($COL_ID), 1)) FROM $TableName;"
        Write-Host "  Imported data from $csvFile into $TableName table"
    }

    #$csvRootFolder = Join-Path $workspaceRoot "pain\data\actual"
    $csvRootFolder = Join-Path $workspaceRoot "pain\data\dummy\data_types"
    Write-Host "Filling database with data..."
    if ($FillTarget) {
        Fill-Table "${FillTarget}pain" (Join-Path $csvRootFolder "$FillTarget.csv") "/tmp/$FillTarget.csv"
    }
    else {
        Fill-Table $TN_EMO (Join-Path $csvRootFolder "emo.csv") "/tmp/emo.csv"
        Fill-Table $TN_ENV (Join-Path $csvRootFolder "env.csv") "/tmp/env.csv"
        Fill-Table $TN_PHYS (Join-Path $csvRootFolder "phys.csv") "/tmp/phys.csv"
        Fill-Table $TN_SOCIOECO (Join-Path $csvRootFolder "socioeco.csv") "/tmp/socioeco.csv"
        Fill-Table $TN_EXPERIMENTAL (Join-Path $csvRootFolder "experimental.csv") "/tmp/experimental.csv"
    }
    Write-Host "Finished importing data!"
}
elseif ($Test) {
    Write-Host "Testing database connection and contents..."
    docker exec -it $containerId psql -U postgres -d pain_db -c "SELECT * FROM $TN_ENV LIMIT 7;"
}
elseif ($Reset) {
    function Drop {
        param ($Type, $TableName)

        docker exec $containerId psql -U postgres -d pain_db -c "DROP $Type IF EXISTS $TableName;"
        Write-Host " -dropped $Type $TableName"
    }

    Write-Host "Resetting database..."
    # drop data tables
    Drop "TABLE" $TN_EMO
    Drop "TABLE" $TN_ENV
    Drop "TABLE" $TN_PHYS
    Drop "TABLE" $TN_SOCIOECO
    Drop "TABLE" $TN_EXPERIMENTAL
    # drop user tables
    Drop "TABLE" $TNM_TOGGLE
    Drop "TABLE" $TNM_STEP
    Drop "TABLE" $TNM_VIS
    Drop "TABLE" $TNM_USER_COORDINATES
    Drop "TABLE" $TNM_USERS
    # drop types
    Drop "TYPE" ${TYPE_TOGGLE_KIND}
    Drop "TYPE" ${TYPE_TOGGLE_ELEM}
    Drop "TYPE" ${TYPE_VIS_MODE}
    Write-Host "Done dropping!"
}
elseif ($Connect) {
    Write-Host "Connecting to database..."
    docker exec -it $containerId psql -U postgres -d pain_db #"\dt"
}
elseif ($Clear) {
    Write-Host "Clearing table ${Clear}"
    docker exec -it $containerId psql -U postgres -d pain_db -c "TRUNCATE ${Clear}"
}
elseif ($ExportMetrics) {
    function Export {
        param ($TableName, $DestFile)

        docker exec $containerId psql -U postgres -d pain_db `
            -c "\copy $TableName TO STDOUT WITH (FORMAT CSV, HEADER)" `
            > $DestFile
        if ($?) {
            Write-Host " -exported ${TableName} to ${DestFile}"
        }
        else {
            Write-Host " -FAILED to export ${TableName} to ${DestFile}"
        }
    }

    Write-Host "Exporting metrics & user IDs..."
    if ((Get-Item ${ExportMetrics}) -is [System.IO.DirectoryInfo]) {
        $timeStamp = get-date -f yyyy-MM-dd-HH-mm-ss
        Export $TNM_TOGGLE (Join-Path ${ExportMetrics} "${TNM_TOGGLE}_${timeStamp}.csv")
        Export $TNM_STEP (Join-Path ${ExportMetrics} "${TNM_STEP}_${timeStamp}.csv")
        Export $TNM_VIS (Join-Path ${ExportMetrics} "${TNM_VIS}_${timeStamp}.csv")
        Export $TNM_USER_COORDINATES (Join-Path ${ExportMetrics} "${TNM_USER_COORDINATES}_${timeStamp}.csv")
        Export $TNM_USERS (Join-Path ${ExportMetrics} "${TNM_USERS}_${timeStamp}.csv")
    }
    else {
        Write-Host "ERROR: Provided path is not a folder!"
    }
}
else {
    Write-Host "Usage: .\populate-db.ps1 -Init | -Fill | -Test | -Reset | -Info"
    Write-Host "  -Init  : Initialize database schema (run once)"
    Write-Host "  -Fill  : Fill database with dummy data (run after init)"
    Write-Host "        -FillTarget: additional argument to determine which table to fill"
    Write-Host "  -Test  : Test database connection and contents"
    Write-Host "  -Reset : Reset database by dropping all known tables"
    Write-Host "  -Connect  : Connect to the Database"
    Write-Host "  -Clear : Clears all rows from a specified table"
    Write-Host "  -ExportMetrics: Exports the data inside metric tables to csv files located in the specified folder"
}
