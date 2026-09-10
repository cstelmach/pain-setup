#!/bin/bash -e
# Bash script to initialize, fill, test, and reset the pain database

# Parse command line arguments
if [ $# -gt 0 ]; then
    # Get the script directory and workspace root
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    WORKSPACE_ROOT="$(dirname "$SCRIPT_DIR")"
    COMPOSE_FILE="$WORKSPACE_ROOT/docker-compose.yml"

    # Check if compose file exists
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo "Error: Compose file not found at $COMPOSE_FILE. Run ./setup.sh -Up first to generate it." >&2
        exit 1
    fi

    # Get the pain-db container ID
    CONTAINER_ID=$(docker compose -f "$COMPOSE_FILE" ps -q pain-db)
    echo "Found pain-db container with ID: $CONTAINER_ID"

    # Check if container is running
    if [ -z "$CONTAINER_ID" ]; then
        echo "Error: No running pain-db container found. Start the stack first with ./setup.sh -Up" >&2
        exit 1
    fi
    
    # parse input
    if [ $# -gt 1 ]; then
        CONFIG_FILE="$2"
    else
        CONFIG_FILE="$SCRIPT_DIR/db-config.env"
    fi
    # load config file
    if [ -f "$CONFIG_FILE" ]; then
        # parse the values from the config file (one "key=value" per line)
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" == \#* ]] && continue
            printf -v "$key" '%s' "$value"
        done < $CONFIG_FILE
    else
        echo "Missing DB config: $CONFIG_FILE" >&2
        exit 1
    fi

    # Check which operation is requested
    # ############################################################
    #   INIT
    # ############################################################
    if [ $1 == "--init" ]; then
        create_table() {
            # $1... table name
            # $2... additional column information
            echo "  Creating table $1..."
            docker exec -it "$CONTAINER_ID" psql -U postgres -d pain_db -c "CREATE TABLE $1 ($COL_ID SERIAL PRIMARY KEY $2);"
        }
        create_data_table() {
            # $1... table name
            # $2... additional column information
            create_table $1 ", $COL_AGGR_ID INTEGER REFERENCES $1($COL_ID), $COL_VALUE FLOAT NOT NULL, $COL_CATEGORY TEXT NOT NULL $2"
        }
        create_metrics_table() {
            # $1... table name
            # $2... additional column information
            create_table $1 ", $COL_DT $TYPE_DT NOT NULL, $COL_USER_ID INTEGER REFERENCES $TNM_USERS($COL_ID) $2"
        }
        create_enum() {
            # $1... enum name
            # $2... all enum values
            docker exec -it $CONTAINER_ID psql -U postgres -d pain_db -c "CREATE TYPE $1 AS ENUM ($2);"
        }
        echo "Initializing database schema..."
        # initialize database schema based on config file
        # initialize tables for our data
        create_data_table $TN_EMO ", $COL_COUNTRY TEXT NOT NULL, $COL_WORD TEXT NOT NULL"
        create_data_table $TN_ENV ", $COL_LAT FLOAT NOT NULL, $COL_LNG FLOAT NOT NULL"
        create_data_table $TN_PHYS ", $COL_LAT FLOAT NOT NULL, $COL_LNG FLOAT NOT NULL"
        create_data_table $TN_SOCIOECO ", $COL_COUNTRY TEXT NOT NULL"
        create_data_table $TN_EXPERIMENTAL ", $COL_LAT FLOAT NOT NULL, $COL_LNG FLOAT NOT NULL"

        # initialize enums for metrics tables
        create_enum ${TYPE_TOGGLE_KIND} "${VALUES_TYPE_TOGGLE_KIND}"
        create_enum ${TYPE_TOGGLE_ELEM} "'${TN_EMO}', '${TN_ENV}', '${TN_PHYS}', '${TN_SOCIOECO}', '${TN_EXPERIMENTAL}', ${VALUES_TYPE_TOGGLE_ELEM_PAIN}, ${VALUES_TYPE_TOGGLE_ELEM_TEMPORALITY}, ${VALUES_TYPE_TOGGLE_ELEM_RELATIONS}"
        create_enum ${TYPE_VIS_MODE} "${VALUES_TYPE_VIS_MODE}"
        # initialize tables for usage metrics
        create_table $TNM_USERS ", $COL_DT $TYPE_DT NOT NULL, $COL_USER_ID TEXT NOT NULL"
        create_metrics_table $TNM_USER_COORDINATES ", $COL_LAT FLOAT NOT NULL, $COL_LNG FLOAT NOT NULL"
        create_metrics_table $TNM_TOGGLE ", $COL_KIND TEXT NOT NULL, $COL_ELEM TEXT NOT NULL, $COL_ENABLED BOOL NOT NULL"
        create_metrics_table $TNM_STEP ", $COL_STEP SMALLINT NOT NULL CHECK ($COL_STEP BETWEEN 0 AND $TYPE_STEP_MAX)"
        create_metrics_table $TNM_VIS ", $COL_VIS_MODE TEXT NOT NULL"
        # The additive analytics schema is shared with upgrades of existing installations.
        docker exec -i "$CONTAINER_ID" psql -X -v ON_ERROR_STOP=1 -U postgres -d pain_db \
            < "$SCRIPT_DIR/migrations/20260909-interaction-events.sql" || exit 1
        exit 0

    # ############################################################
    #   FILL
    # ############################################################
    elif [ $1 == "--fill" ]; then
        fill_table() {
            #$1... table name
            #$2... source path
            #$3... destination path
            echo "Filling $1 with dummy data..."
            docker cp "$2" "$CONTAINER_ID:$3"
            # copy data from CSV into the table
            docker exec $CONTAINER_ID psql -U postgres -d pain_db -c "COPY $1 FROM '$3' CSV HEADER;"
            # reset the sequence for the table's serial ID column
            docker exec $CONTAINER_ID psql -U postgres -d pain_db -c "SELECT setval(pg_get_serial_sequence('$1', '$COL_ID'), COALESCE(MAX($COL_ID), 1)) FROM $1;"
            echo "  Imported data from $2 into $1 table"
        }

        if [ $# -gt 2 ]; then
            CSV_ROOT_FOLDER="$3"
        else
            CSV_ROOT_FOLDER="../pain-data"
        fi
        if [ $# -gt 3 ]; then
            TARGET_TABLE="$4"
            fill_table "${TARGET_TABLE}pain" "${CSV_ROOT_FOLDER}/${TARGET_TABLE}.csv" "/tmp/${TARGET_TABLE}.csv"
        else
            echo "Filling database with dummy data..."
            fill_table $TN_EMO "${CSV_ROOT_FOLDER}/emo.csv" "/tmp/emo.csv"
            fill_table $TN_ENV "${CSV_ROOT_FOLDER}/env.csv" "/tmp/env.csv"
            fill_table $TN_PHYS "${CSV_ROOT_FOLDER}/phys.csv" "/tmp/phys.csv"
            fill_table $TN_SOCIOECO "${CSV_ROOT_FOLDER}/socioeco.csv" "/tmp/socioeco.csv"
            fill_table $TN_EXPERIMENTAL "${CSV_ROOT_FOLDER}/experimental.csv" "/tmp/experimental.csv"
        fi

        exit 0

    # ############################################################
    #   TEST
    # ############################################################
    elif [ $1 == "--test" ]; then
        echo "Testing database connection and contents..."
        if [ $# -gt 2 ]; then
            LIMIT="$3"
        else
            LIMIT="7"
        fi
        docker exec -it "$CONTAINER_ID" psql -U postgres -d pain_db -c "SELECT * FROM $TABLE_NAME LIMIT '$LIMIT';"
        exit 0
    elif [ $1 == "--connect" ]; then
        echo "Connecting to database..."
        docker exec -it $CONTAINER_ID psql -U postgres -d pain_db
    # ############################################################
    #   RESET
    # ############################################################
    elif [ $1 == "--reset" ]; then
        drop() {
            #$1... TABLE or TYPE, depending on what we want to delete
            #$2... table name
            docker exec -it "$CONTAINER_ID" psql -U postgres -d pain_db -c "DROP $1 IF EXISTS $2;"
        }
        echo "Resetting database..."
        # drop data tables
        drop "TABLE" $TN_EMO
        drop "TABLE" $TN_ENV
        drop "TABLE" $TN_PHYS
        drop "TABLE" $TN_SOCIOECO
        drop "TABLE" $TN_EXPERIMENTAL
        # drop user tables
        drop "TABLE" $TNM_TOGGLE
        drop "TABLE" $TNM_STEP
        drop "TABLE" $TNM_VIS
        drop "TABLE" $TNM_USER_COORDINATES
        drop "TABLE" $TNM_USERS
        # drop types
        drop "TYPE" ${TYPE_TOGGLE_KIND}
        drop "TYPE" ${TYPE_TOGGLE_ELEM}
        drop "TYPE" ${TYPE_VIS_MODE}
        exit 0
    elif [ $1 == "--clear" ]; then
        echo "Clearing table = ${3}";
        docker exec -it "$CONTAINER_ID" psql -U postgres -d pain_db -c "TRUNCATE ${3};"
        exit 0
    elif [ $1 == "--export" ]; then
        export_metrics() {
            #$1... table name
            #$2... destination file
            echo "Exporting $1 to ${2}"
            # copy data from CSV into the table
            docker exec $CONTAINER_ID psql -U postgres -d pain_db -c "\copy $1 TO STDOUT WITH (FORMAT CSV, HEADER)" > ${2}
            if [ $? -eq 0 ]; then
                echo "  - successfully exported $1 to ${2}"
            else
                echo "  - FAILED to export $1 to ${2}" >&2
            fi
        }

        echo "Exporting user metrics..."
        if [ $# -gt 2 ]; then
            CSV_ROOT_FOLDER="$3"
        else
            CSV_ROOT_FOLDER="../db-export"
        fi
        if [[ -d $CSV_ROOT_FOLDER ]]; then
            TIME_STAMP=`date +%s`
            export_metrics $TNM_TOGGLE "${CSV_ROOT_FOLDER}/${TNM_TOGGLE}_${TIME_STAMP}.csv"
            export_metrics $TNM_STEP "${CSV_ROOT_FOLDER}/${TNM_STEP}_${TIME_STAMP}.csv"
            export_metrics $TNM_VIS "${CSV_ROOT_FOLDER}/${TNM_VIS}_${TIME_STAMP}.csv"
            export_metrics $TNM_USER_COORDINATES "${CSV_ROOT_FOLDER}/${TNM_USER_COORDINATES}_${TIME_STAMP}.csv"
            export_metrics $TNM_USERS "${CSV_ROOT_FOLDER}/${TNM_USERS}_${TIME_STAMP}.csv"
            exit 0
        else
            echo "ERROR: ${CSV_ROOT_FOLDER} is not a folder!" >&2
            exit 1
        fi
    fi
fi

# If no valid argument is provided, print usage
echo "Usage: ./populate-db.sh [--init] [--fill] [--test] [--reset]"
echo "  --init   : Initialize database schema (run once)"
echo "  --fill   : Fill database with data (run after init)"
echo "  --test   : Test database connection and contents"
echo "  --reset  : Reset database by dropping all tables"
echo "  --clear  : Clears target table by truncating it"
echo "  --export : Export user metrics stored in database as CSVs to target folder path"
exit 1
