#!/bin/bash

### === SECTION: COLOR DEFINITIONS START ===
# ANSI color and style codes
# Reset
RESET="\e[0m"
# --- Standard Foreground Colors ---
BLACK="\e[30m"
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
WHITE="\e[37m"
# --- Bright Foreground Colors ---
BRIGHT_BLACK="\e[90m"
BRIGHT_RED="\e[91m"
BRIGHT_GREEN="\e[92m"
BRIGHT_YELLOW="\e[93m"
BRIGHT_BLUE="\e[94m"
BRIGHT_MAGENTA="\e[95m"
BRIGHT_CYAN="\e[96m"
BRIGHT_WHITE="\e[97m"
# --- Bold, Underline, Blink (optional bling) ---
BOLD="\e[1m"
UNDERLINE="\e[4m"
BLINK="\e[5m"
### === SECTION: COLOR DEFINITIONS END ===
### === SECTION: ENVIRONMENT LOADING START ===
# Set base directory and verify .env safety before sourcing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  # Check for unquoted spaces BEFORE sourcing
  if grep -qE '^[A-Za-z_]+=[^"].*\s+.*[^"]$' "$ENV_FILE" | grep -vE '^\s*:'; then
    echo -e "${YELLOW}âš ï¸  Warning: One or more .env variables contain spaces and are not quoted.${RESET}"
    echo -e "${RED}âŒ Please quote these variables in .env before running the script.${RESET}"
    echo -e "Example: SCRIPT_AUTHOR=\"Bob Smith\""
    exit 1
  fi

  set -a
  source "$ENV_FILE"
  set +a
else
  echo "âš ï¸  Warning: .env file not found at $ENV_FILE"
fi
### === SECTION: ENVIRONMENT LOADING END ===
### === SECTION: DEFAULT VARIABLE SETUP START ===
# Timestamps, backup/log paths, defaults
: "${SCRIPT_VERSION:?SCRIPT_VERSION not set in .env}"
: "${SCRIPT_AUTHOR:?SCRIPT_AUTHOR not set in .env}"
: "${WEBHOOK_URL:?WEBHOOK_URL not set in .env}"
: "${RETENTION_DAYS:=7}"
: "${LOG_RETENTION_DAYS:=30}"
: "${RETRY_LOG_RETENTION_DAYS:=30}"
: "${LOG_MAX_SIZE:=10M}"
: "${MAX_BACKUP_SIZE:=2G}"
: "${BACKUP_DIR_BASE:=/backups}"
: "${LOG_DIR_BASE:=/var/log/pg_backup_logs}"
: "${FAILED_FILE_PATH:=/tmp/pg_failed_dbs.txt}"

: "${TO_SUCCESS_DB_MSG:?TO_SUCCESS_DB_MSG not set in .env}"
: "${TO_FAILED_DB_MSG:?TO_FAILED_DB_MSG not set in .env}"
: "${TO_TEST_MSG:?TO_TEST_MSG not set in .env}"
: "${TO_FAILONLY_MSG:?TO_FAILONLY_MSG not set in .env}"
: "${TO_FAILTEST_MSG:?TO_FAILTEST_MSG not set in .env}"
: "${WH_FAILTEST_MSG:?WH_FAILTEST_MSG not set in .env}"
: "${WH_MANUAL_DB_SUMMARY_MSG:?WH_MANUAL_DB_SUMMARY_MSG not set in .env}"
: "${TO_DEBUG_MSG:?TO_DEBUG_MSG not set in .env}"
: "${TO_NO_OPTION_MSG:?TO_NO_OPTION_MSG not set in .env}"
: "${TO_CLEANUP_MSG:?TO_CLEANUP_MSG not set in .env}"
: "${TO_DISKSPACE_MSG:?TO_DISKSPACE_MSG not set in .env}"
: "${TO_SUMMARY_MSG:?TO_SUMMARY_MSG not set in .env}"
: "${TO_BACKUP_DONE_MSG:?TO_BACKUP_DONE_MSG not set in .env}"
: "${TO_JOB_START_MSG:?TO_JOB_START_MSG not set in .env}"
: "${TO_RETRY_SKIP_MSG:?TO_RETRY_SKIP_MSG not set in .env}"
: "${TO_ROTATE_MSG:?TO_ROTATE_MSG not set in .env}"
: "${TO_MISSING_DB_MSG:?TO_MISSING_DB_MSG not set in .env}"
: "${TO_REQUIREMENT_FAIL_MSG:?TO_REQUIREMENT_FAIL_MSG not set in .env}"

: "${TO_INSTALL_PACKAGE_MSG:?TO_INSTALL_PACKAGE_MSG not set in .env}"
: "${WH_INSTALL_SUCCESS_MSG:?WH_INSTALL_SUCCESS_MSG not set in .env}"
: "${WH_INSTALL_FAIL_MSG:?WH_INSTALL_FAIL_MSG not set in .env}"
: "${WH_RETRY_SKIP_MSG:?WH_RETRY_SKIP_MSG not set in .env}"

: "${WH_NO_OPTION_MSG:?WH_NO_OPTION_MSG not set in .env}"
: "${WH_DISKSPACE_MSG:?WH_DISKSPACE_MSG not set in .env}"
: "${WH_TEST_MSG:?WH_TEST_MSG not set in .env}"
: "${WH_DEBUG_MSG:?WH_DEBUG_MSG not set in .env}"
: "${WH_CLEANUP_MSG:?WH_CLEANUP_MSG not set in .env}"
: "${WH_FAILONLY_MSG:?WH_FAILONLY_MSG not set in .env}"

FILE_TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
TIMESTAMP=$(date +"%Y-%m-%d %I:%M%p")
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$LOCAL_IP" ] && LOCAL_IP="127.0.0.1"
DATE_FOLDER=$(date +"%Y-%m-%d")
BACKUP_DIR="$BACKUP_DIR_BASE/$DATE_FOLDER"
LOG_DIR="$LOG_DIR_BASE"
ARCHIVE_DIR="$LOG_DIR/archived"
LOG_FILE="$LOG_DIR/pg_backup_${DATE_FOLDER}.log"
FAILED_FILE="$FAILED_FILE_PATH"
HOSTNAME=$(hostname)

mkdir -p "$LOG_DIR" "$ARCHIVE_DIR" "$BACKUP_DIR"
touch "$LOG_FILE"
chmod 700 "$BACKUP_DIR"

LOG_SUMMARY=false
LOG_MODE=false
### === SECTION: DEFAULT VARIABLE SETUP END ===
# === FUNCTION: Expand Environment Variable ===
expand_env_var() {
  local RAW_INPUT="$1"
  local OUTPUT
  eval "OUTPUT=\"$RAW_INPUT\""
  echo -e "$OUTPUT"
}
# === FUNCTION: send_webhook ===
send_webhook() {
  local MESSAGE="$1"
  local FORCE="${2:-false}"
  if $FORCE || (! $SILENT_MODE && ! $QUIET_MODE); then
    jq -n --arg content "$MESSAGE" --arg username "PG Backup Bot" \
    '{username: $username, content: $content}' | \
    curl -s -H "Content-Type: application/json" -X POST -d @- "$WEBHOOK_URL"
  fi
}
### === SECTION: PRE-FLIGHT CHECK START ===
# Verify required binaries and permissions before proceeding
REQUIRED_CMDS=("psql" "pg_dump" "gzip" "jq" "sudo" "curl" "bc")

MISSING_CMDS=()
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING_CMDS+=("$cmd")
  fi
done

if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
  echo -e "${RED}âŒ Missing required commands:${RESET} ${MISSING_CMDS[*]}"
  read -rp "â“ Do you want to attempt to install them now? [y/N] " INSTALL_MISSING
  if [[ "$INSTALL_MISSING" =~ ^[Yy]$ ]]; then
  for pkg in "${MISSING_CMDS[@]}"; do
  ITEM="$pkg"
  #TO_MSG=$(expand_env_var "$TO_INSTALL_PACKAGE_MSG")
  #echo -e "$TO_MSG"
  TO_MSG=$(expand_env_var "${TO_INSTALL_PACKAGE_MSG//\$ITEM/$ITEM}")
  echo -e "$TO_MSG"


  if apt-get install -y "$pkg" >/dev/null 2>&1; then
    WH_MSG=$(eval "echo \"$WH_INSTALL_SUCCESS_MSG\"")
    send_webhook "$WH_MSG" true
  else
    WH_MSG=$(eval "echo \"$WH_INSTALL_FAIL_MSG\"")
    send_webhook "$WH_MSG" true
    echo -e "${RED}âŒ Failed to install $pkg. Aborting.${RESET}"
    exit 1
  fi
done
    echo -e "${GREEN}âœ… All missing packages installed successfully.${RESET}"
  else
    echo -e "${RED}âŒ Aborted due to missing requirements.${RESET}"
    exit 1
  fi
fi
# Check sudo access for postgres user
if ! sudo -l -U postgres >/dev/null 2>&1; then
  echo -e "${RED}âŒ Error: Cannot execute commands as 'postgres'. Check sudoers or permissions.${RESET}"
  exit 1
fi
### === SECTION: PRE-FLIGHT CHECK END ===
### === SECTION: FUNCTION LIST START ===
# List of all defined functions for reference
# Function Index:
# - backup_database           | Dump, compress, and validate a single DB
# - check_system_requirements | Validate all prerequisites and permissions
# - discover_databases        | Resolve list of databases to back up
# - disk_space_check          | Abort if disk space is below 4GB
# - expand_env_var            | Expand .env-style variables with embedded codes | Above Pre-Flight Check
# - generate_failure_summary  | Construct failure webhook message
# - generate_retry_summary    | Construct retry webhook message
# - generate_success_summary  | Construct success webhook message
# - list_databases            | Print all non-template DBs with size
# - log                       | Colorized or plain log entry writer
# - print_config              | Print loaded .env configuration
# - rotate_old_files          | Apply retention policy for backups and logs
# - run_backup_loop           | Iterate over databases and run backup
# - send_webhook              | Send formatted message to Discord webhook
# - show_about                | Print version, author, and features
# - show_help                 | Show CLI flag usage guide
# - summary_report            | Final exit logic + summary + webhook
# - validate_database_list    | Validate single DB(s) passed via --database
### === SECTION: FUNCTION LIST END ===
### === SECTION: FUNCTION DEFINITIONS START ===
# All actual function blocks go here
# === FUNCTION: backup_database ===
backup_database() {
  local DB="$1"


# === SIMULATION BLOCK FOR TESTING --retry ===
#if [ "$DB" = "simulate_success_db" ]; then
#  echo "Simulated successful backup for $DB" > /dev/null
#elif [ "$DB" = "simulate_fail_db" ]; then
#  echo "$DB" >> "$FAILED_FILE"
#  TO_MSG="$(expand_env_var "$TO_FAILED_DB_MSG") $DB"
#  if $VERBOSE_MODE && [ -t 1 ]; then
#    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [${RED}ERROR${RESET}] $TO_MSG"
#  fi
#  log "ERROR" "$TO_MSG"
#  FAILED+=("$DB")
#  return
#elif [ "$DB" = "simulate_missing_db" ]; then
#  echo "$DB" >> "$FAILED_FILE"
#  TO_MSG="$(expand_env_var "$TO_MISSING_DB_MSG")"
#  log "WARN" "$TO_MSG"
#  MSG=$(eval "echo \"$WH_MISSING_DB_MSG\"")
#  send_webhook "$MSG"
#  FAILED+=("$DB")
#  return
#fi
# === END SIMULATION BLOCK ===
# === SIMULATION BLOCK FOR TESTING --retry ===
#if [ "$DB" = "simulate_success_db" ]; then
#  echo "Simulated successful backup for $DB" > /dev/null

#elif [ "$DB" = "simulate_fail_db" ]; then
#  echo "$DB" >> "$FAILED_FILE"
#  TO_MSG="$(expand_env_var "$TO_FAILED_DB_MSG") $DB"
#  if $VERBOSE_MODE && [ -t 1 ]; then
#    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [${RED}ERROR${RESET}] $TO_MSG"
#  fi
#  log "ERROR" "$TO_MSG"
#  FAILED+=("$DB")
#  return

#elif [ "$DB" = "simulate_missing_db" ]; then
#  echo "$DB" >> "$FAILED_FILE"
#  TO_MSG="$(expand_env_var "$TO_MISSING_DB_MSG")"
#  log "WARN" "$TO_MSG"
#  MSG=$(eval "echo \"$WH_MISSING_DB_MSG\"")
#  send_webhook "$MSG"
#  FAILED+=("$DB")
#  return
#fi
# === END SIMULATION BLOCK ===


  BACKUP_FILE="${BACKUP_DIR}/${DB}_${FILE_TIMESTAMP}.sql.gz"

  if sudo -u postgres pg_dump -U postgres -d "$DB" 1> >(gzip > "$BACKUP_FILE") 2>>"$LOG_FILE"; then

    RAW_SUCCESS_MSG="${TO_SUCCESS_DB_MSG//\$DB/$DB}"
    TO_MSG=$(expand_env_var "$RAW_SUCCESS_MSG")

    if $VERBOSE_MODE && ! $SHOW_SUMMARY_ONLY && [ -t 1 ]; then
      echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [${YELLOW}INFO${RESET}] $TO_MSG"
    fi

    OLD_VERBOSE=$VERBOSE_MODE
    VERBOSE_MODE=false
    CLEAN_TO_MSG=$(echo -e "$TO_MSG" | sed -r 's/\x1B\[[0-9;]*[JKmsu]//g')
    log "INFO" "$CLEAN_TO_MSG"
    VERBOSE_MODE=$OLD_VERBOSE

    if $RETRY_MODE && [ -f "$FAILED_FILE" ]; then
      grep -vx "$DB" "$FAILED_FILE" > "${FAILED_FILE}.tmp" && mv "${FAILED_FILE}.tmp" "$FAILED_FILE"
    fi

    FILESIZE=$(stat -c%s "$BACKUP_FILE")
    FILESIZE_MB=$(echo "scale=2; $FILESIZE / 1024 / 1024" | bc)
    BACKUP_SIZES+=("${DB}:${FILESIZE_MB}")
    TOTAL_BACKUP_SIZE=$(echo "$TOTAL_BACKUP_SIZE + $FILESIZE_MB" | bc)

    case "$MAX_BACKUP_SIZE" in
      *G) MAX_BACKUP_SIZE_BYTES=$(( ${MAX_BACKUP_SIZE%G} * 1024 * 1024 * 1024 )) ;;
      *M) MAX_BACKUP_SIZE_BYTES=$(( ${MAX_BACKUP_SIZE%M} * 1024 * 1024 )) ;;
      *K) MAX_BACKUP_SIZE_BYTES=$(( ${MAX_BACKUP_SIZE%K} * 1024 )) ;;
      *)  MAX_BACKUP_SIZE_BYTES=$MAX_BACKUP_SIZE ;;
    esac

    if [ "$FILESIZE" -gt "$MAX_BACKUP_SIZE_BYTES" ]; then
      WARNINGS+=("$DB exceeded $MAX_BACKUP_SIZE ($(du -h "$BACKUP_FILE" | cut -f1))")
    fi
  else
    TO_MSG="$(expand_env_var "$TO_FAILED_DB_MSG")$DB"
    if $VERBOSE_MODE && [ -t 1 ]; then
      echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [${RED}ERROR${RESET}] $TO_MSG"
    fi

    OLD_VERBOSE=$VERBOSE_MODE
    VERBOSE_MODE=false
    log "ERROR" "$TO_MSG"
    VERBOSE_MODE=$OLD_VERBOSE

    FAILED+=("$DB")
    echo "$DB" >> "$FAILED_FILE"
  fi
}
# === FUNCTION: check_system_requirements ===
check_system_requirements() {
    echo -e "${BOLD}${BRIGHT_WHITE}ðŸ” PostgreSQL Backup Script - Requirements Check${RESET}"
    echo -e "$(expand_env_var "$TO_LINE")"
    echo -e "${BRIGHT_CYAN}ðŸ”§ Required Commands:${RESET}"
      for cmd in "${REQUIRED_CMDS[@]}"; do
      if command -v "$cmd" >/dev/null 2>&1; then
        echo -e "  ${GREEN}âœ” $cmd${RESET}"
      else
        echo -e "  ${RED}âœ˜ $cmd (Missing)${RESET}"
      fi
    done
        echo -e "\n${BRIGHT_CYAN}ðŸ” Sudo Permissions:${RESET}"
      if sudo -l -U postgres >/dev/null 2>&1; then
  ITEM="sudo as postgres"
  echo -e "$(expand_env_var "$TO_REQUIREMENT_PASS_MSG")"
else
  ITEM="sudo as postgres"
    echo -e "$(expand_env_var "$TO_REQUIREMENT_FAIL_MSG")"
fi
        echo -e "\n${BRIGHT_CYAN}ðŸ“ Writable Directories:${RESET}"
      for path in "$BACKUP_DIR_BASE" "$LOG_DIR_BASE" "$FAILED_FILE_PATH"; do
      if [ -w "$(dirname "$path")" ]; then
        echo -e "  ${GREEN}âœ” Writable: $path${RESET}"
    else
        echo -e "  ${RED}âœ˜ Not writable: $path${RESET}"
      fi
    done
        echo -e "\n${BRIGHT_CYAN}ðŸ“„ Required .env Keys:${RESET}"
    VARS=(
      SCRIPT_VERSION SCRIPT_AUTHOR WEBHOOK_URL RETENTION_DAYS LOG_MAX_SIZE
      MAX_BACKUP_SIZE LOG_DIR_BASE BACKUP_DIR_BASE FAILED_FILE_PATH
      TO_NO_OPTION_MSG WH_NO_OPTION_MSG WH_TEST_MSG WH_DEBUG_MSG
      WH_CLEANUP_MSG WH_FAILONLY_MSG
    )
    for var in "${VARS[@]}"; do
      if [ -z "${!var}" ]; then
        echo -e "  ${RED}âœ˜ $var not set${RESET}"
      else
        echo -e "  ${GREEN}âœ” $var${RESET}"
      fi
    done
        echo -e "\n${GREEN}âœ… Check complete.${RESET}"
    exit 0
}
# === FUNCTION: discover_databases ===
discover_databases() {
  if $RETRY_MODE; then
  if [ ! -f "$FAILED_FILE" ]; then
    TO_MSG=$(expand_env_var "$TO_RETRY_SKIP_MSG")
    log "INFO" "$TO_MSG"
    WH_MSG=$(eval "echo \"$WH_RETRY_SKIP_MSG\"")
    send_webhook "$WH_MSG" true
    exit 0
  fi
    mapfile -t ALL_RETRY_DBS < <(grep -v '^#' "$FAILED_FILE")
    DATABASES=()
    SKIPPED_MISSING=()
    for DB in "${ALL_RETRY_DBS[@]}"; do
      if sudo -u postgres psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -q 1; then
        DATABASES+=("$DB")
      else
        SKIPPED_MISSING+=("$DB")
        log "WARN" "âš ï¸ Skipped: '$DB' no longer exists on server."
        grep -vxF "$DB" "$FAILED_FILE" > "${FAILED_FILE}.tmp" && mv "${FAILED_FILE}.tmp" "$FAILED_FILE"
      fi
    done
    if [ ${#DATABASES[@]} -eq 0 ]; then
  generate_retry_summary
  # If all databases were invalid, clear the FAILED_FILE
  if [ ${#SKIPPED_MISSING[@]} -gt 0 ]; then
    > "$FAILED_FILE"
  fi
  send_webhook "$RETRY_MESSAGE" true
  exit 0
fi
  elif [ -n "$SINGLE_DB" ]; then
    validate_database_list
  else
    DATABASES=($(sudo -u postgres psql -U postgres -t -c \
      "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');" | xargs))
  fi
  if [ ${#DATABASES[@]} -eq 0 ]; then
    echo "No databases found to back up." >> "$LOG_FILE"
    exit 1
  fi
}
# === FUNCTION: disk_space_check ===
    disk_space_check() {
      AVAIL=$(df "$BACKUP_DIR_BASE" | awk 'NR==2 {print $4}')
      AVAIL_HR=$(df -h "$BACKUP_DIR_BASE" | awk 'NR==2 {print $4}')
      #AVAIL=3000000  # Force fake low disk space
      if [ "$AVAIL" -lt 4194304 ]; then
        WH_MSG=$(eval "echo \"$WH_DISKSPACE_MSG\"")
        TO_MSG=$(expand_env_var "$TO_DISKSPACE_MSG")

        echo "$TO_MSG" >> "$LOG_FILE"
        $VERBOSE_MODE && echo -e "$TO_MSG"

        send_webhook "$WH_MSG" true
        exit 1
fi
    }
# === FUNCTION: generate_failure_summary ===
    generate_failure_summary() {
     RAW_MSG=$(eval "echo \"$WH_FINAL_FAIL_HEADER\"")
    STATUS=$(echo -e "$RAW_MSG")
 if [ -n "$SINGLE_DB" ]; then
  SUCCESS_LIST=()
  for db in "${DATABASES[@]}"; do
    skip=false
    for fail in "${FAILED[@]}"; do
      if [[ "$db" == "$fail" ]]; then skip=true; break; fi
    done
    if ! $skip; then SUCCESS_LIST+=("$db"); fi
  done

  SUCCESS_DBS=$(printf "%s\n" "${SUCCESS_LIST[@]}")
  FAILED_DBS=$(printf "%s\n" "${FAILED[@]}")
  RAW_MSG=$(eval "echo \"$WH_MANUAL_DB_SUMMARY_MSG\"")
  STATUS=$(echo -e "$RAW_MSG")
fi


if [ -n "$SINGLE_DB" ] || [ ${#FAILED[@]} -lt ${#DATABASES[@]} ]; then
  STATUS+="

âœ… Successful Databases:
\`\`\`"
  for db in "${DATABASES[@]}"; do
    skip=false
    for fail in "${FAILED[@]}"; do
      if [[ "$db" == "$fail" ]]; then skip=true; break; fi
    done
    if ! $skip; then
      STATUS+="$(printf '%s\n' "$db")"
    fi
  done
  STATUS+="\`\`\`"
fi


STATUS+="

ðŸ“¦ Failed Databases:
\`\`\`
${FAILED[*]}
\`\`\`"

    }
# === FUNCTION: generate_retry_summary ===
generate_retry_summary() {
  local SUCCESS_LIST=()
  for db in "${DATABASES[@]}"; do
    if [[ ! " ${FAILED[*]} " =~ " ${db} " ]]; then
      SUCCESS_LIST+=("$db")
    fi
  done
  RAW_MSG=$(eval "echo -e \"$WH_RETRY_MSG_HEADER\"")
  RETRY_MESSAGE="$RAW_MSG"
  if [ ${#SUCCESS_LIST[@]} -gt 0 ]; then
    RETRY_MESSAGE+="

âœ… Successfully Retried:
\`\`\`
$(printf "%s\n" "${SUCCESS_LIST[@]}")
\`\`\`"
  fi

  if [ ${#FAILED[@]} -gt 0 ]; then
    RETRY_MESSAGE+="

âŒ Still Failing:
\`\`\`
$(printf "%s\n" "${FAILED[@]}")
\`\`\`"
  fi
  if [ ${#SKIPPED_MISSING[@]} -gt 0 ]; then
    RETRY_MESSAGE+="

âš ï¸ Skipped (Invalid or Deleted):
\`\`\`
$(printf "%s\n" "${SKIPPED_MISSING[@]}")
\`\`\`"
  fi
}
# === FUNCTION: generate_success_summary ===
    generate_success_summary() {
      RAW_MSG=$(eval "echo \"$WH_FINAL_OK_HEADER\"")
      STATUS=$(echo -e "$RAW_MSG")
      if [ -n "$SINGLE_DB" ]; then
  RAW_MSG=$(eval "echo \"$WH_MANUAL_DB_HEADER\"")
  STATUS=$(echo -e "$RAW_MSG")

  STATUS+="

\`\`\`
$(printf '%s\n' "${DATABASES[@]}")
\`\`\`"
  return
fi




#    STATUS+="

 #   âœ… All databases backed up successfully."
    }
# === FUNCTION: list_databases ===
    list_databases() {
      echo -e "ðŸ“‹ Available PostgreSQL Databases with Sizes:"
      echo -e "$(expand_env_var "$TO_LINE")"
      RESULT=$(sudo -u postgres psql -U postgres -AtF '|' -c \
        "SELECT datname, pg_size_pretty(pg_database_size(datname)) \
         FROM pg_database \
         WHERE datistemplate = false \
         ORDER BY datname;")
      COUNT=0
      if [ -n "$RESULT" ]; then
        echo "$RESULT" | grep -vE '^(postgres|template0|template1)' | while IFS='|' read -r db size; do
        echo -e "${YELLOW}--> ${CYAN}$(printf '%-30s' "$db")${RESET} ${MAGENTA}$(printf '%10s' "$size")${RESET}"
        COUNT=$((COUNT+1))
      done
        TOTAL=$(echo "$RESULT" | grep -vcE '^(postgres|template0|template1)')
        echo -e "Total databases: $TOTAL"
      else
        echo "âš ï¸  Unable to retrieve database list."
      fi
    }
# === FUNCTION: log ===
    log() {
      local level="$1"; shift
      local message="$*"
      local ts="[$(date '+%Y-%m-%d %H:%M:%S')]"
      # Always write plain version to log file (no ANSI codes)
      local stripped_message=$(echo "$message" | sed -r 's/\x1B\[[0-9;]*[JKmsu]//g')
      echo "${ts} [$level] $stripped_message" >> "$LOG_FILE"
      # Show colorized output to terminal if verbose
      if [ "$VERBOSE_MODE" = true ] && [ -t 1 ]; then
        local color="$RESET"
        case "$level" in
          INFO)  color="$YELLOW" ;;
          WARN)  color="$BRIGHT_YELLOW" ;;
          ERROR) color="$RED" ;;
        esac
        local colored_msg="$message"
        colored_msg="${colored_msg//âœ…/${GREEN}âœ…${RESET}}"
        colored_msg="${colored_msg//âŒ/${RED}âŒ${RESET}}"
        colored_msg="${colored_msg/Success:/${GREEN}Success:${RESET}}"
        colored_msg="${colored_msg/Failed:/${RED}Failed:${RESET}}"
        echo -e "${ts} [${color}${level}${RESET}] $colored_msg"
      fi
    }
# === FUNCTION: print_config ===
    print_config() {
      echo -e "ðŸ›  Loaded Configuration from .env:"
      echo -e "$(expand_env_var "$TO_LINE")"
      echo -e "${CYAN}SCRIPT_VERSION          = ${YELLOW}$SCRIPT_VERSION"
      echo -e "${CYAN}SCRIPT_AUTHOR           = ${YELLOW}$SCRIPT_AUTHOR"
      echo -e "${CYAN}WEBHOOK_URL             = ${YELLOW}${WEBHOOK_URL:0:60}..."
      echo -e "${CYAN}RETENTION_DAYS          = ${YELLOW}$RETENTION_DAYS"
      echo -e "${CYAN}LOG_RETENTION_DAYS      = ${YELLOW}$LOG_RETENTION_DAYS"
      echo -e "${CYAN}RETRY_LOG_RETENTION_DAYS= ${YELLOW}$RETRY_LOG_RETENTION_DAYS"
      echo -e "${CYAN}LOG_MAX_SIZE            = ${YELLOW}$LOG_MAX_SIZE"
      echo -e "${CYAN}MAX_BACKUP_SIZE         = ${YELLOW}$MAX_BACKUP_SIZE"
      echo -e "${CYAN}BACKUP_DIR_BASE         = ${YELLOW}$BACKUP_DIR_BASE"
      echo -e "${CYAN}LOG_DIR_BASE            = ${YELLOW}$LOG_DIR_BASE"
      echo -e "${CYAN}FAILED_FILE_PATH        = ${YELLOW}$FAILED_FILE_PATH"
      echo -e "${CYAN}HOSTNAME                = ${YELLOW}$HOSTNAME"
      echo -e "${CYAN}LOCAL_IP                = ${YELLOW}$LOCAL_IP"
      echo -e "${CYAN}DATE_FOLDER             = ${YELLOW}$DATE_FOLDER"
      echo -e "${CYAN}BACKUP_DIR              = ${YELLOW}$BACKUP_DIR"
      echo -e "${CYAN}LOG_FILE                = ${YELLOW}$LOG_FILE${RESET}"
      echo
    }
# === FUNCTION: rotate_old_files ===
    rotate_old_files() {
      # Delete backup files older than retention
      find "$BACKUP_DIR_BASE" -type f -name "*.sql.gz" -mtime +$RETENTION_DAYS -delete
      # Remove backup folders (e.g., /backups/YYYY-MM-DD) older than retention
      find "$BACKUP_DIR_BASE" -mindepth 1 -maxdepth 1 -type d -exec bash -c '
        for folder; do
          folder_date=$(basename "$folder")
          if [[ "$folder_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            if [[ "$(date -d "$folder_date + $RETENTION_DAYS days" +%s)" -lt "$(date +%s)" ]]; then
              rm -rf "$folder"
            fi
          fi
        done
      ' bash {} +
      # Delete old log files
      find "$LOG_DIR" -type f -name "*.log*" -mtime +$LOG_RETENTION_DAYS -delete
      # Delete old retry logs
      find "$ARCHIVE_DIR" -type f -name "failed_db_retries_*.log" -mtime +$RETRY_LOG_RETENTION_DAYS -delete
    #if [ -t 1 ]; then
    #  TO_MSG=$(expand_env_var "$TO_ROTATE_MSG")
    #    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [${YELLOW}INFO${RESET}] $TO_MSG"
    #fi
#if $VERBOSE_MODE && [ -t 1 ]; then
#  TO_MSG=$(expand_env_var "$TO_ROTATE_MSG")
#  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [${YELLOW}INFO${RESET}] $TO_MSG"
#fi
# âœ… Log only (if needed), but let the main --cleanup block control terminal
#OLD_VERBOSE=$VERBOSE_MODE
#VERBOSE_MODE=false  # Suppress terminal output
#TO_MSG=$(expand_env_var "$TO_ROTATE_MSG")
#CLEAN_LOG_MSG=$(echo -e "$TO_MSG" | sed -r 's/\x1B\[[0-9;]*[JKmsu]//g')
#log "INFO" "$CLEAN_LOG_MSG"
#VERBOSE_MODE=$OLD_VERBOSE
# Only log rotation message IF NOT in cleanup mode
if ! $CLEANUP_MODE; then
  OLD_VERBOSE=$VERBOSE_MODE
  VERBOSE_MODE=false
  TO_MSG=$(expand_env_var "$TO_ROTATE_MSG")
  CLEAN_LOG_MSG=$(echo -e "$TO_MSG" | sed -r 's/\x1B\[[0-9;]*[JKmsu]//g')
  log "INFO" "$CLEAN_LOG_MSG"
  VERBOSE_MODE=$OLD_VERBOSE
fi



    }
# === FUNCTION: run_backup_loop ===
    run_backup_loop() {
      for DB in "${DATABASES[@]}"; do
        backup_database "$DB"
      done
    }
# === FUNCTION: send_webhook ===
#    send_webhook() {
#      local MESSAGE="$1"
#      local FORCE="${2:-false}"
#      if $FORCE || (! $SILENT_MODE && ! $QUIET_MODE); then
#        jq -n --arg content "$MESSAGE" --arg username "PG Backup Bot" \
#        '{username: $username, content: $content}' | \
#        curl -s -H "Content-Type: application/json" -X POST -d @- "$WEBHOOK_URL"
#      fi
#    }
# === FUNCTION: show_about ===
    show_about() {
      echo -e ""
      echo -e "${BOLD}${BRIGHT_WHITE}ðŸ›¡ ${BOLD}${BRIGHT_CYAN}PostgreSQL Backup Script - About${RESET}"
      echo -e "$(expand_env_var "$TO_LINE")"
      echo -e "${WHITE}This script automates PostgreSQL database backups with built-in safety and reporting."
      echo -e ""
      echo -e "${BRIGHT_WHITE}ðŸ“¦ ${CYAN}Version           : ${YELLOW}$SCRIPT_VERSION${RESET}"
      echo -e "${BRIGHT_WHITE}ðŸ‘¤ ${CYAN}Author            : ${YELLOW}$SCRIPT_AUTHOR${RESET}"
      echo -e "${BRIGHT_WHITE}ðŸ–¥  ${CYAN}Host              :${YELLOW} $HOSTNAME (${LOCAL_IP})${RESET}"
      echo -e ""
      echo -e "${BRIGHT_WHITE}âœ¨ ${BOLD}${BRIGHT_CYAN}Features${RESET}"
      echo -e "$(expand_env_var "$TO_LINE")"
      echo -e "${WHITE}- Timestamped and compressed backups"
      echo -e "- Discord webhook alerts (success, warning, fail)"
      echo -e "- Retry support (--retry)"
      echo -e "- Disk space checks (<4GB aborts)"
      echo -e "- Backup size warnings"
      echo -e "- Cleanup for backups/logs/retries"
      echo -e "- Quiet & silent modes"
      echo -e "- .env-driven configuration"
      echo -e ""
      echo -e "${BRIGHT_WHITE}âš™ï¸ ${BOLD}${BRIGHT_CYAN}Requirements${RESET}"
      echo -e "$(expand_env_var "$TO_LINE")"
      echo -e "${WHITE}- Bash + gzip + curl + sudo + jq"
      echo -e "- Internet access (for webhook)"
      echo -e "- Cron-compatible"
      echo -e ""
      echo -e "${BRIGHT_WHITE}ðŸ“ ${BOLD}${BRIGHT_CYAN}Default Paths${RESET}"
      echo -e "$(expand_env_var "$TO_LINE")"
      echo -e "${WHITE}- Backup Dir      : $BACKUP_DIR_BASE/YYYY-MM-DD/"
      echo -e "- Log Dir         : $LOG_DIR_BASE/"
      echo -e "- Archive         : $LOG_DIR_BASE/archived/"
      echo -e ""
      echo -e ""
      echo -e "${BRIGHT_WHITE}ðŸ”§ ${BOLD}${BRIGHT_CYAN}Required .env Settings${RESET}"
      echo -e "$(expand_env_var "$TO_LINE")"
      echo -e "${WHITE}- SCRIPT_VERSION, SCRIPT_AUTHOR"
      echo -e "- WEBHOOK_URL"
      echo -e "- RETENTION_DAYS, LOG_MAX_SIZE, MAX_BACKUP_SIZE"
      echo -e "- LOG_DIR_BASE, BACKUP_DIR_BASE, FAILED_FILE_PATH"
      echo -e ""
      echo -e "${BRIGHT_WHITE}ðŸ›  ${BOLD}${BRIGHT_CYAN}Optional Flags${RESET}"
      echo -e "$(expand_env_var "$TO_LINE")"
      echo -e "${WHITE}- --run, --retry, --failtest, --summary"
      echo -e "- --config, --debug, --cleanup"
      echo -e "- --webhook-test, --list-databases"
      echo -e "- --summary-only, --verbose, --quiet, --silent"
      echo -e ""
      echo -e "${BRIGHT_WHITE}ðŸ“† ${BOLD}${BRIGHT_CYAN}Cron Example${RESET}"
      echo -e "$(expand_env_var "$TO_LINE")"
      echo -e "${WHITE}30 2 * * * /usr/sbin/scripts/pg_backup38.sh --run >> /var/log/pg_backup_cron.log 2>&1"
      echo -e ""
    }
# === FUNCTION: show_help ===
    show_help() {
      echo -e "${BOLD}${CYAN}ðŸ“˜ PostgreSQL Backup Script - Help${RESET}"
      echo -e "Usage: ./pg_backup.sh [OPTIONS]"
      echo -e "$(expand_env_var "$TO_LINE")"
      echo -e "${BRIGHT_CYAN}ðŸ”¹ Backup Flags${RESET}"
      echo -e "  --database=<name>     Only back up the specified database"
      echo -e "  --failonly            Simulate a backup failure without running backup"
      echo -e "  --failtest            Run backup and simulate a failure"
      echo -e "  --retry               Retry failed backups from previous run"
      echo -e "  --run                 Perform full PostgreSQL backup"
      echo
      echo -e "${BRIGHT_CYAN}ðŸ”¹ Output & Logging Flags${RESET}"
      echo -e "  --log                 Enable logging to log file"
      echo -e "  --quiet               Suppress all output (overrides verbose)"
      echo -e "  --silent              Suppress Discord webhook notifications"
      echo -e "  --summary             Write final summary block to log file"
      echo -e "  --summary-only        Suppress all output except the final summary"
      echo -e "  --verbose             Output progress to terminal"
      echo
      echo -e "${BRIGHT_CYAN}ðŸ”¹ Utility & Misc Flags${RESET}"
      echo -e "  --about               Show script version, author, and features"
      echo -e "  --cleanup             Delete old backups and logs based on retention policy"
      echo -e "  --config              Show current configuration values from .env"
      echo -e "  --check               Run system/environment requirements check"
      echo -e "  --debug               Check available disk space and exit"
      echo -e "  --help, -h            Display this help message"
      echo -e "  --list-databases      Show all PostgreSQL databases available for backup"
      echo -e "  --version             Show script version and exit"
      echo -e "  --webhook-test        Send a test message to the configured Discord webhook"
      echo
    }
# === FUNCTION: simulate_failonly ===
simulate_failonly() {
  TO_MSG=$(expand_env_var "$TO_FAILONLY_MSG")
  CLEAN_TO_MSG=$(echo -e "$TO_MSG" | sed -r 's/\x1B\[[0-9;]*[JKmsu]//g')

  if $VERBOSE_MODE && [ -t 1 ]; then
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [${RED}ERROR${RESET}] $TO_MSG"
  fi

  OLD_VERBOSE=$VERBOSE_MODE
  VERBOSE_MODE=false
  log "ERROR" "$CLEAN_TO_MSG"
  VERBOSE_MODE=$OLD_VERBOSE

  echo "simulated_failure_db" > "$FAILED_FILE"

  WH_HEADER=$(eval "echo \"$WH_FAILONLY_MSG\"")
  WH_MSG="${WH_HEADER}

**Failed databases:**
\`\`\`
simulated_failure_db
\`\`\`"
  send_webhook "$WH_MSG"
  exit 2
}

# === FUNCTION: simulate_failtest ===
simulate_failtest() {
  TO_MSG=$(expand_env_var "$TO_FAILTEST_MSG")
  CLEAN_TO_MSG=$(echo -e "$TO_MSG" | sed -r 's/\x1B\[[0-9;]*[JKmsu]//g')

  if $VERBOSE_MODE && [ -t 1 ]; then
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [${RED}ERROR${RESET}] $TO_MSG"
  fi

  OLD_VERBOSE=$VERBOSE_MODE
  VERBOSE_MODE=false
  log "ERROR" "$CLEAN_TO_MSG"
  VERBOSE_MODE=$OLD_VERBOSE

  echo "simulated_failure_test" > "$FAILED_FILE"

  WH_HEADER=$(eval "echo \"$WH_FAILTEST_MSG\"")
  WH_MSG="${WH_HEADER}

**Failed databases:**
\`\`\`
simulated_failure_test
\`\`\`"
  send_webhook "$WH_MSG"
  exit 2
}

### === FUNCTION: summary_report ===
    summary_report() {
      local SCRIPT_END_TIME=$(date +%s)
      local DURATION_SEC=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
      local DURATION_FMT=$(printf '%02dh:%02dm:%02ds' $((DURATION_SEC/3600)) $((DURATION_SEC%3600/60)) $((DURATION_SEC%60)))
      EXIT_CODE=$([ ${#FAILED[@]} -eq 0 ] && echo 0 || echo 2)

      if $RETRY_MODE && [ ${#FAILED[@]} -eq 0 ] && [ -f "$FAILED_FILE" ]; then
        mv "$FAILED_FILE" "$ARCHIVE_DIR/failed_db_retries_${FILE_TIMESTAMP}.log"
      fi
      if $CLEANUP_MODE; then
      rotate_old_files
      fi
      # Generate final STATUS message
      if [ ${#FAILED[@]} -eq 0 ]; then
        generate_success_summary
      else
        generate_failure_summary
      fi
      # Print the summary block
      if $SHOW_SUMMARY_OUTPUT && [ "$VERBOSE_MODE" = true ]; then
      if [ -t 1 ]; then
        TO_MSG=$(expand_env_var "$TO_LINE")
        echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [${YELLOW}INFO${RESET}] $TO_MSG"
      fi
        OLD_VERBOSE=$VERBOSE_MODE
        VERBOSE_MODE=false
        VERBOSE_MODE=$OLD_VERBOSE

        log "INFO" "ðŸ“‹ PG BACKUP SUMMARY"
        log "INFO" "ðŸ–¥  Hostname       : $HOSTNAME"
        log "INFO" "ðŸŒ Local IP       : $LOCAL_IP"
        log "INFO" "â±  Duration       : $DURATION_FMT"
        log "INFO" "ðŸ“¦ Databases      : ${#DATABASES[@]}"
        log "INFO" "âœ… Successes      : $(( ${#DATABASES[@]} - ${#FAILED[@]} ))"
        log "INFO" "âŒ Failures       : ${#FAILED[@]}"
        log "INFO" "ðŸ“ Total Size     : ${TOTAL_BACKUP_SIZE} MB"
        if [ ${#BACKUP_SIZES[@]} -gt 0 ]; then
          log "INFO" "ðŸ“‚ Backup Sizes:"
          for entry in "${BACKUP_SIZES[@]}"; do
            dbname="${entry%%:*}"
            size="${entry##*:}"
            log "INFO" "   â†’ $(printf '%-18s' "$dbname") : ${size} MB"
          done
        fi
        log "INFO" "ðŸ’¾ Free Disk Space : $AVAIL_HR"
        log "INFO" "ðŸ“ Backup Dir     : $BACKUP_DIR"
        log "INFO" "ðŸ“ Log File       : $LOG_FILE"

if [ -t 1 ]; then
  TO_MSG=$(expand_env_var "$TO_LINE")
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [${YELLOW}INFO${RESET}] $TO_MSG"
fi
        OLD_VERBOSE=$VERBOSE_MODE
        VERBOSE_MODE=false
        VERBOSE_MODE=$OLD_VERBOSE
      elif $LOG_SUMMARY; then
  OLD_VERBOSE=$VERBOSE_MODE
  VERBOSE_MODE=false
  log "INFO" "ðŸ“‹ PG BACKUP SUMMARY"
  log "INFO" "ðŸ’»  Hostname       : $HOSTNAME"
  log "INFO" "ðŸŒ Local IP       : $LOCAL_IP"
  log "INFO" "â±  Duration       : $DURATION_FMT"
  log "INFO" "ðŸ“¦ Databases      : ${#DATABASES[@]}"
  log "INFO" "âœ… Successes      : $(( ${#DATABASES[@]} - ${#FAILED[@]} ))"
  log "INFO" "âŒ Failures       : ${#FAILED[@]}"
  log "INFO" "ðŸ“€ Total Size     : ${TOTAL_BACKUP_SIZE} MB"
  log "INFO" "ðŸ’¾ Free Disk Space : $AVAIL_HR"
  log "INFO" "ðŸ“ Backup Dir     : $BACKUP_DIR"
  log "INFO" "ðŸ“ Log File       : $LOG_FILE"
  VERBOSE_MODE=$OLD_VERBOSE
fi
      # Send webhook (either retry or regular status)
      if $RETRY_MODE; then
        generate_retry_summary
        send_webhook "$RETRY_MESSAGE" $SHOW_SUMMARY_OUTPUT
      elif [ ${#FAILED[@]} -eq 0 ]; then
        send_webhook "$STATUS" $SHOW_SUMMARY_OUTPUT
      else
        send_webhook "$STATUS" $SHOW_SUMMARY_OUTPUT
      fi
      exit $EXIT_CODE
    }
# === FUNCTION: validate_database_list ===
    validate_database_list() {
      IFS=',' read -ra RAW_DBS <<< "$SINGLE_DB"
      DATABASES=()
      for DB in "${RAW_DBS[@]}"; do
        if sudo -u postgres psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -q 1; then
          DATABASES+=("$DB")
        else
          TO_MSG=$(expand_env_var "$TO_MISSING_DB_MSG")
          #echo -e "$TO_MSG"
          log "WARN" "$TO_MSG"
          MSG=$(eval "echo \"$WH_MISSING_DB_MSG\"")
          send_webhook "$MSG"
        fi
      done
      IFS=',' read -ra DATABASES <<< "$SINGLE_DB"
    }
### === SECTION: SCRIPT TIMER START ===
# Set script start time for duration tracking
SCRIPT_START_TIME=$(date +%s)
### === SECTION: SCRIPT TIMER END ===
### === SECTION: FLAG PARSING START ===
# Parse command-line arguments into flags
CHECK_MODE=false
SHOW_DATABASES=false
SHOW_SUMMARY_OUTPUT=false
SHOW_CONFIG=false
SHOW_SUMMARY_ONLY=false
SHOW_HELP=false
SHOW_ABOUT=false
RUN_MODE=false
RETRY_MODE=false
FAIL_TEST=false
FAIL_ONLY=false
DEBUG_MODE=false
CLEANUP_MODE=false
QUIET_MODE=false
VERBOSE_MODE=false
SILENT_MODE=false
WEBHOOK_TEST=false
SHOW_VERSION=false
SINGLE_DB=""

for arg in "$@"; do
  case "$arg" in
    --run) RUN_MODE=true ;;
    --retry) RETRY_MODE=true ;;
    --failtest) FAIL_TEST=true ;;
    --failonly) FAIL_ONLY=true ;;
    --cleanup) CLEANUP_MODE=true ;;
    --debug) DEBUG_MODE=true ;;
    --webhook-test) WEBHOOK_TEST=true ;;
    --database=*) SINGLE_DB="${arg#*=}" ;;
    --config) SHOW_CONFIG=true ;;
    --check) CHECK_MODE=true ;;
    --about) SHOW_ABOUT=true ;;
    --verbose) VERBOSE_MODE=true ;;
    --silent) SILENT_MODE=true ;;
    --quiet) QUIET_MODE=true ;;
    --summary) LOG_SUMMARY=true ;;
    --summary-only) SHOW_SUMMARY_ONLY=true ;;
    --log) LOG_MODE=true ;;
    --help|-h) SHOW_HELP=true ;;
    --version) SHOW_VERSION=true ;;
    --list-databases) SHOW_DATABASES=true ;;
    *)
      echo -e "${RED}âŒ Error: Unknown option '$arg'${RESET}"
      echo -e "Run with ${CYAN}--help${RESET} to see available options and correct usage."
      exit 1 ;;
  esac
  shift || true
done
### === SECTION: FLAG PARSING END ===
### === SECTION: NO FLAG FALLBACK HANDLER START ===
# If no flags were provided, send warning and exit
if ! $SHOW_HELP && ! $SHOW_ABOUT && ! $SHOW_VERSION && ! $RUN_MODE && ! $RETRY_MODE && \
   ! $FAIL_TEST && ! $FAIL_ONLY && ! $DEBUG_MODE && ! $CLEANUP_MODE && \
   ! $SHOW_CONFIG && ! $SHOW_DATABASES && ! $WEBHOOK_TEST && ! $CHECK_MODE; then

MSG1=$(expand_env_var "$TO_NO_OPTION_MSG")
echo -e "$MSG1"
echo "[$(date)] âš ï¸  Script called with no command options." >> "$LOG_FILE"
MSG=$(eval "echo \"$WH_NO_OPTION_MSG\"")
send_webhook "$MSG"
  exit 1
fi
### === SECTION: NO FLAG FALLBACK HANDLER END ===
### === SECTION: HELP FLAG HANDLER START ===
# Show help and exit
# Enable summary output when both --summary and --verbose are used
if $LOG_SUMMARY && $VERBOSE_MODE; then
  SHOW_SUMMARY_OUTPUT=true
fi
if $SHOW_SUMMARY_ONLY; then
  LOG_SUMMARY=true
  QUIET_MODE=true
  SHOW_SUMMARY_OUTPUT=true  # âœ… Still allow summary block to be shown
fi
if $SHOW_HELP; then
  show_help
  exit 0
fi
### === SECTION: HELP FLAG HANDLER END ===
### === SECTION: ABOUT FLAG HANDLER START ===
# Show script about/version details
if $SHOW_ABOUT; then
  show_about
  exit 0
fi
### === SECTION: ABOUT FLAG HANDLER END ===
### === SECTION: VERSION FLAG HANDLER START ===
if $SHOW_VERSION; then
  echo -e "${BOLD}${CYAN}PostgreSQL Backup Script - Version ${YELLOW}${SCRIPT_VERSION}${RESET}"
  exit 0
fi
### === SECTION: VERSION FLAG HANDLER END ===
# === SECTION: CHECK FLAG GUARD START ===
# If --check is used with other flags, exit with an error
if $CHECK_MODE && (
  $SHOW_HELP || $SHOW_ABOUT || $SHOW_VERSION || $RUN_MODE || $RETRY_MODE || \
  $FAIL_TEST || $FAIL_ONLY || $DEBUG_MODE || $CLEANUP_MODE || $SHOW_CONFIG || \
  $SHOW_DATABASES || $WEBHOOK_TEST || $LOG_SUMMARY || $SHOW_SUMMARY_ONLY || \
  $QUIET_MODE || $SILENT_MODE || $VERBOSE_MODE || [ -n "$SINGLE_DB" ]
); then
  echo -e "${RED}âŒ The --check flag must be used alone.${RESET}"
  echo -e "   ${YELLOW}Example:${RESET} ./pg_backup.sh --check"
  exit 1
fi
# === SECTION: CHECK FLAG GUARD END ===
# === SECTION: CHECK FLAG HANDLER START ===
if $CHECK_MODE; then
  check_system_requirements
fi
# === SECTION: CHECK FLAG HANDLER END ===
### === SECTION: CONFIG FLAG HANDLER START ===
# Print loaded .env configuration
if $SHOW_CONFIG; then
  print_config
  exit 0
fi
### === SECTION: CONFIG FLAG HANDLER END ===
### === SECTION: WEBHOOK TEST FLAG HANDLER START ===
# Send test webhook message and exit
if $WEBHOOK_TEST; then
  WH_MSG=$(eval "echo \"$WH_TEST_MSG\"")
  TO_MSG=$(expand_env_var "$TO_TEST_MSG")
  send_webhook "$WH_MSG"
  $VERBOSE_MODE && echo -e "$TO_MSG"
  exit 0
fi
### === SECTION: WEBHOOK TEST FLAG HANDLER END ===
### === SECTION: DEBUG, CLEANUP, FAILONLY HANDLERS START ===
# Diskspace check, cleanup, and fail-only simulation
if $DEBUG_MODE; then
  SILENT_MODE=true
  VERBOSE_MODE=true
  AVAIL_HR=$(df -h "$BACKUP_DIR_BASE" | awk 'NR==2 {print $4}')
  WH_MSG=$(eval "echo \"$WH_DEBUG_MSG\"")
  TO_MSG=$(expand_env_var "$TO_DEBUG_MSG")
  echo -e "$TO_MSG"
  send_webhook "$WH_MSG" true
  print_config
  list_databases
  #send_webhook "$MSG" true
  exit 0
fi

if $CLEANUP_MODE; then
  rotate_old_files
  WH_MSG=$(eval "echo \"$WH_CLEANUP_MSG\"")
  TO_MSG=$(expand_env_var "$TO_CLEANUP_MSG")

  #TO_MSG=$(expand_env_var "$TO_CLEANUP_MSG")

  # âœ… Only print to terminal if --verbose
  if $VERBOSE_MODE && [ -t 1 ]; then
    TO_MSG=$(expand_env_var "$TO_CLEANUP_MSG")
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [${YELLOW}INFO${RESET}] $TO_MSG"
  fi

  # âœ… Always log cleanup message (stripped of ANSI codes)
  CLEAN_LOG_MSG=$(echo -e "$TO_MSG" | sed -r 's/\x1B\[[0-9;]*[JKmsu]//g')
  OLD_VERBOSE=$VERBOSE_MODE
  VERBOSE_MODE=false
  log "INFO" "$CLEAN_LOG_MSG"
  VERBOSE_MODE=$OLD_VERBOSE


  # âœ… Always send webhook
  send_webhook "$WH_MSG"
  exit 0
fi

if $FAIL_ONLY; then
  simulate_failonly
fi

if $FAIL_TEST; then
  simulate_failtest
fi


### === SECTION: DEBUG, CLEANUP, FAILONLY HANDLERS END ===
### === SECTION: LIST DATABASES FLAG HANDLER START ===
# Show available databases and exit cleanly
if $SHOW_DATABASES; then
  list_databases
  exit 0
fi
### === SECTION: LIST DATABASES FLAG HANDLER END ===
### === SECTION: DISK SPACE CHECK START ===
# Verify free disk space threshold
disk_space_check
### === SECTION: DISK SPACE CHECK END ===
### === SECTION: DATABASE DISCOVERY START ===
# Resolve list of databases to back up
TO_MSG=$(expand_env_var "$TO_JOB_START_MSG")
log "INFO" "$TO_MSG"
discover_databases
### === SECTION: DATABASE DISCOVERY END ===
### === SECTION: BACKUP LOOP START ===
# Begin backup process for all selected databases
# (setup logs, reset arrays, etc.)
# Always log the backup start, but only show to terminal in verbose mode
FAILED=()
WARNINGS=()
BACKUP_SIZES=()
TOTAL_BACKUP_SIZE=0
### === SECTION: BACKUP LOOP END ===
### === SECTION: BACKUP FUNCTION START ===
# Run backup function per database and handle --failtest
run_backup_loop


### === SECTION: BACKUP FUNCTION END ===
### === SECTION: POST-BACKUP HANDLING START ===
# Generate final report, cleanup, webhook, and exit
if $VERBOSE_MODE && ! $SHOW_SUMMARY_ONLY; then
  TO_MSG=$(expand_env_var "$TO_BACKUP_DONE_MSG")
  if [ -t 1 ]; then
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [${YELLOW}INFO${RESET}] $TO_MSG"
  fi
  OLD_VERBOSE=$VERBOSE_MODE
  VERBOSE_MODE=false
  TO_MSG=$(expand_env_var "$TO_BACKUP_DONE_MSG")
    log "INFO" "$TO_MSG"
  VERBOSE_MODE=$OLD_VERBOSE
elif ! $SHOW_SUMMARY_ONLY; then
  TO_MSG=$(expand_env_var "$TO_BACKUP_DONE_MSG")
  log "INFO" "$TO_MSG"
fi
# Call final summary function (handles exit + webhook)
summary_report
### === SECTION: POST-BACKUP HANDLING END ===
