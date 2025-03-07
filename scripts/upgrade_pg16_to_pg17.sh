#!/bin/bash

set -e

DATA_DIR="/var/lib/postgresql/data/pgdata"
TEMP_DIR="/var/lib/postgresql/data/pgdata17"
UPGRADE_TEMP_DIR="/var/lib/postgresql/data/upgrade_temp"

if [ ! -d "$TEMP_DIR" ]; then
    echo "Creating necessary directories..."
    mkdir -p $TEMP_DIR
fi

# Create upgrade_temp directory if it doesn't exist
if [ ! -d "$UPGRADE_TEMP_DIR" ]; then
    echo "Creating upgrade_temp directory..."
    mkdir -p $UPGRADE_TEMP_DIR
    chown postgres:postgres $UPGRADE_TEMP_DIR
    chmod 700 $UPGRADE_TEMP_DIR
fi

# Backup the original pg_hba.conf file
echo "Backing up original pg_hba.conf file..."
if [ -f "$DATA_DIR/pg_hba.conf" ]; then
    cp "$DATA_DIR/pg_hba.conf" "$UPGRADE_TEMP_DIR/pg_hba.conf.backup"
    echo "Original pg_hba.conf backed up to $UPGRADE_TEMP_DIR/pg_hba.conf.backup"
else
    echo "Error: pg_hba.conf not found in $DATA_DIR"
    exit 0
fi

# Remove all files in the temporary directory, maybe from previous runs
rm -rf $TEMP_DIR/*

echo "Setting ownership and permissions..."
chown -R postgres:postgres $DATA_DIR
chmod 700 $DATA_DIR

chown -R postgres:postgres $TEMP_DIR
chmod 700 $TEMP_DIR

# Check for postmaster.pid files across the entire filesystem and remove them
echo "Searching for and removing all postmaster.pid files across the filesystem..."
find / -name "postmaster.pid" -type f 2>/dev/null | while read -r pid_file; do
    echo "Removing stale postmaster.pid file found at: $pid_file"
    rm -f "$pid_file"
done

# Check if the cluster is in "in production" state and fix if needed
echo "Checking PostgreSQL 16 cluster state..."
CLUSTER_STATE=$(su - postgres -c "/usr/lib/postgresql/16/bin/pg_controldata $DATA_DIR" | grep "Database cluster state" | awk -F: '{print $2}' | xargs)

if [[ "$CLUSTER_STATE" == "in production" ]]; then
    echo "PostgreSQL 16 cluster is in 'in production' state. Fixing unclean shutdown state using pg_resetwal..."
    su - postgres -c "/usr/lib/postgresql/16/bin/pg_resetwal -f $DATA_DIR"
    echo "PostgreSQL 16 cluster should now be in a clean shutdown state."
else
    echo "PostgreSQL 16 cluster is in '$CLUSTER_STATE' state. No need to run pg_resetwal."
fi

# Initialize temporary PostgreSQL 17 data directory
echo "Initializing temporary PostgreSQL 17 data directory..."
su - postgres -c "/usr/lib/postgresql/17/bin/initdb -D $TEMP_DIR"

# Run pg_upgrade check
echo "Running pg_upgrade check..."

su - postgres -c "/usr/lib/postgresql/17/bin/pg_upgrade \
    --old-datadir=$DATA_DIR \
    --new-datadir=$TEMP_DIR \
    --old-bindir=/usr/lib/postgresql/16/bin \
    --new-bindir=/usr/lib/postgresql/17/bin \
    --old-port=50432 \
    --new-port=50433 \
    --link \
    --check"

echo "Running pg_upgrade..."

su - postgres -c "/usr/lib/postgresql/17/bin/pg_upgrade \
    --old-datadir=$DATA_DIR \
    --new-datadir=$TEMP_DIR \
    --old-bindir=/usr/lib/postgresql/16/bin \
    --new-bindir=/usr/lib/postgresql/17/bin \
    --old-port=50432 \
    --new-port=50433 \
    --link"

echo "Moving upgraded data into place and removing old directory..."
rm -rf $DATA_DIR
mv $TEMP_DIR $DATA_DIR

# Restore the original pg_hba.conf file
echo "Restoring original pg_hba.conf configuration..."
if [ -f "$UPGRADE_TEMP_DIR/pg_hba.conf.backup" ]; then
    cp "$UPGRADE_TEMP_DIR/pg_hba.conf.backup" "$DATA_DIR/pg_hba.conf"
    echo "Original pg_hba.conf restored successfully."
else
    echo "Warning: Could not find pg_hba.conf backup."
    exit 0    
fi

# Make sure permissions are correct
chown -R postgres:postgres $DATA_DIR
chmod 700 $DATA_DIR
chmod 600 $DATA_DIR/pg_hba.conf

echo "PostgreSQL upgrade completed successfully!"
echo "Your data has been upgraded in-place from PostgreSQL 16 to 17."
echo "Remember to keep your backup until you've verified everything works correctly."