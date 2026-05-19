#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

# ==============================================================================
# issues.sh – Batch create GitHub issues from Markdown templates
# ==============================================================================

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
readonly DEFAULT_ISSUES_DIR=".github/issues"

# ------------------------------------------------------------------------------
# Terminal colors using tput (with fallback)
# ------------------------------------------------------------------------------
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
    BOLD=$(tput bold)
    GREEN=$(tput setaf 2)
    ORANGE=$(tput setaf 208)
    RED=$(tput setaf 1)
    WHITE=$(tput setaf 7)
    BLUE=$(tput setaf 4)
    PURPLE=$(tput setaf 5)
    CYAN=$(tput setaf 6)
    NC=$(tput sgr0)
else
    BOLD=""
    GREEN=""
    ORANGE=""
    RED=""
    WHITE=""
    BLUE=""
    PURPLE=""
    CYAN=""
    NC=""
fi

readonly ICON_PASS="${GREEN}✓${NC}"
readonly ICON_WARN="${ORANGE}⚠${NC}"
readonly ICON_FAIL="${RED}✗${NC}"
readonly ICON_INFO="${BLUE}ℹ${NC}"
readonly ICON_SKIP="${WHITE}○${NC}"

# ------------------------------------------------------------------------------
# Global state
# ------------------------------------------------------------------------------
declare -A COUNTS=( ["pass"]=0 ["warn"]=0 ["fail"]=0 ["info"]=0 ["skip"]=0 )
declare -a CHECK_RESULTS=()
declare -A EXISTING_ISSUES

# ------------------------------------------------------------------------------
# Logging functions (bold messages)
# ------------------------------------------------------------------------------
log_info()    { echo -e "${ICON_INFO} ${BLUE}${BOLD}$*${NC}" >&2; COUNTS["info"]=$((COUNTS["info"]+1)); CHECK_RESULTS+=("info"); }
log_warn()    { echo -e "${ICON_WARN} ${ORANGE}${BOLD}$*${NC}" >&2; COUNTS["warn"]=$((COUNTS["warn"]+1)); CHECK_RESULTS+=("warn"); }
log_success() { echo -e "${ICON_PASS} ${GREEN}${BOLD}$*${NC}" >&2; COUNTS["pass"]=$((COUNTS["pass"]+1)); CHECK_RESULTS+=("pass"); }
log_error()   { echo -e "${ICON_FAIL} ${RED}${BOLD}$*${NC}" >&2; COUNTS["fail"]=$((COUNTS["fail"]+1)); CHECK_RESULTS+=("fail"); }

# Special log for duplicate issues – color depends on state, but both are counted as "skip"
log_duplicate() {
    local state="$1"
    local number="$2"
    local title="$3"
    local message="Issue already exists (${state}): #${number} - ${title}"
    if [[ "$state" == "OPEN" ]]; then
        echo -e "${ICON_SKIP} ${WHITE}${BOLD}${message}${NC}" >&2
    else
        echo -e "${ICON_SKIP} ${RED}${BOLD}${message}${NC}" >&2
    fi
    COUNTS["skip"]=$((COUNTS["skip"]+1))
    CHECK_RESULTS+=("skip")
}

fatal() {
    echo -e "\n${ICON_FAIL} ${RED}${BOLD}FATAL ERROR: $1${NC}" >&2
    exit 1
}

# ------------------------------------------------------------------------------
# Tool validation
# ------------------------------------------------------------------------------
validate_required_tools() {
    local required_tools=("gh" "jq" "git")
    local missing=()
    for tool in "${required_tools[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if command -v yq >/dev/null 2>&1; then
        log_info "yq found – using for YAML parsing"
    else
        log_warn "yq not found – falling back to basic grep/sed (may be less reliable)"
    fi
    [[ ${#missing[@]} -eq 0 ]] || fatal "Missing required tools: ${missing[*]}"
    log_success "All required tools are available"
}

# ------------------------------------------------------------------------------
# Text normalization for duplicate detection
# ------------------------------------------------------------------------------
normalize_title() {
    echo "$1" | perl -CSDA -pe 's/\p{So}//g' 2>/dev/null | sed 's/[^[:alnum:]]//g' | tr '[:upper:]' '[:lower:]' \
        || echo "$1" | tr -d '[:punct:]' | tr '[:upper:]' '[:lower:]'
}

# ------------------------------------------------------------------------------
# Cache existing issues (both open and closed)
# ------------------------------------------------------------------------------
cache_existing_issues() {
    log_info "Fetching existing issues (open and closed) from GitHub..."
    local all_issues
    all_issues=$(gh issue list --state all --limit 1000 --json title,number,state 2>/dev/null || echo '[]')
    EXISTING_ISSUES=()
    local count=0
    while IFS= read -r issue; do
        [[ -z "$issue" ]] && continue
        local title=$(echo "$issue" | jq -r '.title')
        local number=$(echo "$issue" | jq -r '.number')
        local state=$(echo "$issue" | jq -r '.state')   # "OPEN" or "CLOSED"
        local normalized=$(normalize_title "$title")
        EXISTING_ISSUES["$normalized"]="$state|$number|$title"
        count=$((count+1))
    done < <(echo "$all_issues" | jq -c '.[]')
    log_success "Cached $count existing issues (open + closed)"
}

# ------------------------------------------------------------------------------
# Check if an issue already exists (by normalized title)
# Sets globals: EXISTING_STATE, EXISTING_NUMBER, EXISTING_TITLE
# ------------------------------------------------------------------------------
issue_exists() {
    local normalized="$1"
    if [[ -n "${EXISTING_ISSUES[$normalized]:-}" ]]; then
        IFS='|' read -r EXISTING_STATE EXISTING_NUMBER EXISTING_TITLE <<< "${EXISTING_ISSUES[$normalized]}"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# Parse YAML frontmatter from an issue markdown file
# Sets globals: ISSUE_TITLE, ISSUE_MILESTONE, ISSUE_LABELS_ARRAY, ISSUE_ASSIGNEES_ARRAY
# ------------------------------------------------------------------------------
parse_issue_metadata() {
    local file="$1"
    ISSUE_TITLE=""
    ISSUE_MILESTONE=""
    ISSUE_LABELS_ARRAY=()
    ISSUE_ASSIGNEES_ARRAY=()

    local frontmatter
    frontmatter=$(awk '/^---$/ { if (++n == 1) next; if (n == 2) exit } n == 1' "$file")

    if [[ -z "$frontmatter" ]]; then
        log_error "No YAML frontmatter found in $file"
        return 1
    fi

    if command -v yq >/dev/null 2>&1; then
        ISSUE_TITLE=$(echo "$frontmatter" | yq eval '.title' - 2>/dev/null | sed 's/^"//;s/"$//')
        ISSUE_MILESTONE=$(echo "$frontmatter" | yq eval '.milestone' - 2>/dev/null | sed 's/^"//;s/"$//')
        local labels_raw
        labels_raw=$(echo "$frontmatter" | yq eval '.labels' - 2>/dev/null)
        if [[ "$labels_raw" != "null" ]]; then
            if [[ "$labels_raw" =~ ^\[.*\]$ ]]; then
                mapfile -t ISSUE_LABELS_ARRAY < <(echo "$frontmatter" | yq eval '.labels[]' - 2>/dev/null)
            else
                ISSUE_LABELS_ARRAY=("$labels_raw")
            fi
        fi
        local assignees_raw
        assignees_raw=$(echo "$frontmatter" | yq eval '.assignees' - 2>/dev/null)
        if [[ "$assignees_raw" != "null" ]]; then
            if [[ "$assignees_raw" =~ ^\[.*\]$ ]]; then
                mapfile -t ISSUE_ASSIGNEES_ARRAY < <(echo "$frontmatter" | yq eval '.assignees[]' - 2>/dev/null)
            else
                ISSUE_ASSIGNEES_ARRAY=("$assignees_raw")
            fi
        fi
    else
        ISSUE_TITLE=$(echo "$frontmatter" | grep -m1 '^title:' | sed 's/^title: *//;s/^"//;s/"$//')
        ISSUE_MILESTONE=$(echo "$frontmatter" | grep -m1 '^milestone:' | sed 's/^milestone: *//;s/^"//;s/"$//')
        local labels_line
        labels_line=$(echo "$frontmatter" | grep -m1 '^labels:' | sed 's/^labels: *//')
        if [[ -n "$labels_line" ]]; then
            labels_line=$(echo "$labels_line" | sed 's/[][]//g')
            IFS=',' read -ra ISSUE_LABELS_ARRAY <<< "$labels_line"
            for i in "${!ISSUE_LABELS_ARRAY[@]}"; do
                ISSUE_LABELS_ARRAY[$i]=$(echo "${ISSUE_LABELS_ARRAY[$i]}" | sed 's/^ *//;s/ *$//')
            done
        fi
        local assignees_line
        assignees_line=$(echo "$frontmatter" | grep -m1 '^assignees:' | sed 's/^assignees: *//')
        if [[ -n "$assignees_line" ]]; then
            assignees_line=$(echo "$assignees_line" | sed 's/[][]//g')
            IFS=',' read -ra ISSUE_ASSIGNEES_ARRAY <<< "$assignees_line"
            for i in "${!ISSUE_ASSIGNEES_ARRAY[@]}"; do
                ISSUE_ASSIGNEES_ARRAY[$i]=$(echo "${ISSUE_ASSIGNEES_ARRAY[$i]}" | sed 's/^ *//;s/ *$//')
            done
        fi
    fi

    ISSUE_TITLE=$(echo "$ISSUE_TITLE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    ISSUE_MILESTONE=$(echo "$ISSUE_MILESTONE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [[ -z "$ISSUE_TITLE" ]]; then
        log_error "Missing 'title' in $file"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Create a single issue from a markdown file
# Returns: 0 = created, 1 = skipped (duplicate open or closed), 2 = error
# ------------------------------------------------------------------------------
create_issue_from_file() {
    local file="$1"
    local assignee_override="$2"
    local dry_run="${3:-false}"

    if ! parse_issue_metadata "$file"; then
        return 2
    fi

    local normalized_title
    normalized_title=$(normalize_title "$ISSUE_TITLE")
    if issue_exists "$normalized_title"; then
        log_duplicate "$EXISTING_STATE" "$EXISTING_NUMBER" "$ISSUE_TITLE"
        return 1   # skip regardless of state
    fi

    local body
    body=$(awk '/^---$/{f++; next} f>=2' "$file")

    local label_args=()
    for label in "${ISSUE_LABELS_ARRAY[@]}"; do
        [[ -n "$label" ]] && label_args+=("--label" "$label")
    done

    local assignee_arg=""
    if [[ ${#ISSUE_ASSIGNEES_ARRAY[@]} -gt 0 ]]; then
        assignee_arg="--assignee ${ISSUE_ASSIGNEES_ARRAY[0]}"
    elif [[ -n "$assignee_override" ]]; then
        assignee_arg="--assignee $assignee_override"
    fi

    local milestone_arg=""
    if [[ -n "$ISSUE_MILESTONE" ]]; then
        milestone_arg="--milestone \"$ISSUE_MILESTONE\""
    fi

    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY RUN] Would create issue: $ISSUE_TITLE"
        return 0
    fi

    local issue_url
    local cmd="gh issue create --title \"$ISSUE_TITLE\" --body \"$body\" $assignee_arg ${label_args[*]} $milestone_arg"
    if issue_url=$(eval "$cmd" 2>/dev/null); then
        log_success "Created issue: $ISSUE_TITLE → $issue_url"
        return 0
    else
        log_error "Failed to create issue: $ISSUE_TITLE"
        return 2
    fi
}

# ------------------------------------------------------------------------------
# Output helpers (progress bar, summary, signature)
# ------------------------------------------------------------------------------
print_progress_bar() {
    local total=${#CHECK_RESULTS[@]}
    [[ $total -eq 0 ]] && return
    local bar=""
    for r in "${CHECK_RESULTS[@]}"; do
        case "$r" in
            "pass") bar+="🟩" ;;
            "warn") bar+="🟧" ;;
            "fail") bar+="🟥" ;;
            "info") bar+="🟦" ;;
            "skip") bar+="⬛" ;;
        esac
    done
    echo -e "\n${WHITE}Progress: [${bar}] 100% (${total}/${total} checks)${NC}"
}

print_summary() {
    echo -e "\n${CYAN}${BOLD}📊 Summary:${NC}"
    printf "%b  ${GREEN}${BOLD}Created${NC}   ${GREEN}🟢  ⇒ ${GREEN}${BOLD}%d${NC}%b\n" "${ICON_PASS}" "${COUNTS[pass]}" "${NC}"
    printf "%b  ${WHITE}${BOLD}Skipped${NC}   ${WHITE}⚫  ⇒ ${WHITE}${BOLD}%d${NC}%b\n" "${ICON_SKIP}" "${COUNTS[skip]}" "${NC}"
    printf "%b  ${RED}${BOLD}Failed${NC}    ${RED}🔴  ⇒ ${RED}${BOLD}%d${NC}%b\n" "${ICON_FAIL}" "${COUNTS[fail]}" "${NC}"
    printf "%b  ${BLUE}${BOLD}Info${NC}      ${BLUE}🔵  ⇒ ${BLUE}${BOLD}%d${NC}%b\n" "${ICON_INFO}" "${COUNTS[info]}" "${NC}"
    printf "%b  ${ORANGE}${BOLD}Warnings${NC}  ${ORANGE}🟠  ⇒ ${ORANGE}${BOLD}%d${NC}%b\n" "${ICON_WARN}" "${COUNTS[warn]}" "${NC}"
}

print_signature() {
    echo -e "\n${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}                          Author Details                                  ${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}ANUJ KUMAR${NC}"
    echo -e "${CYAN}🏅 QA Lead & AI-Assisted Testing Specialist${NC}"
    echo -e "${ORANGE}📧 Email: ${BLUE}anujpatiyal@live.in${NC}"
    echo -e "${ORANGE}🔗 LinkedIn: ${BLUE}https://www.linkedin.com/in/anuj-kumar-qa/${NC}"
    echo -e "\n${WHITE}Completed at: $(date +"%d-%b-%Y %H:%M:%S")${NC}\n"
}

print_banner() {
    echo -e "\n${PURPLE}╔══════════════════════════════════════════════════════════════╗"
    echo -e "║${NC}${PURPLE}          📝  G I T H U B   I S S U E   C R E A T O R        ${NC}${PURPLE}║"
    echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    local start_time=$(date +%s)
    print_banner

    local assignee=""
    local label_filter=""
    local issues_dir="$DEFAULT_ISSUES_DIR"
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --assignee) assignee="$2"; shift 2 ;;
            --label-filter) label_filter="$2"; shift 2 ;;
            --issues-dir) issues_dir="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            -h|--help)
                cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --assignee USER      Assign created issues to this GitHub user (default: authenticated user)
  --label-filter LABEL Only process issues containing this label (case-insensitive)
  --issues-dir DIR     Directory containing issue markdown files (default: .github/issues)
  --dry-run            Simulate creation without calling GitHub API
  -h, --help           Show this help
EOF
                exit 0
                ;;
            *) fatal "Unknown option: $1" ;;
        esac
    done

    validate_required_tools

    if [[ "$dry_run" == "false" ]]; then
        if ! gh auth status >/dev/null 2>&1; then
            fatal "GitHub CLI not authenticated. Run 'gh auth login'."
        fi
    fi

    if [[ -z "$assignee" ]] && [[ "$dry_run" == "false" ]]; then
        assignee=$(gh api user --jq '.login' 2>/dev/null || echo "")
        [[ -z "$assignee" ]] && fatal "Could not determine current GitHub user. Specify --assignee."
    fi

    if [[ ! -d "$issues_dir" ]]; then
        fatal "Directory not found: $issues_dir"
    fi

    if [[ "$dry_run" == "false" ]]; then
        cache_existing_issues
    else
        log_info "DRY RUN: Skipping cache of existing issues"
    fi

    local files=("$issues_dir"/*.md)
    if [[ ${#files[@]} -eq 1 && ! -f "${files[0]}" ]]; then
        fatal "No .md files found in $issues_dir"
    fi

    log_info "Processing ${#files[@]} issue template(s) from $issues_dir"
    if [[ -n "$assignee" ]]; then
        log_info "Assignee: $assignee"
    fi
    [[ -n "$label_filter" ]] && log_info "Label filter: $label_filter"

    local created=0 skipped=0 failed=0

    for file in "${files[@]}"; do
        [[ -f "$file" ]] || continue

        if [[ -n "$label_filter" ]]; then
            parse_issue_metadata "$file" >/dev/null 2>&1
            local found=false
            for lbl in "${ISSUE_LABELS_ARRAY[@]}"; do
                if [[ "${lbl,,}" == "${label_filter,,}" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == "false" ]]; then
                log_skip "Skipping $file (does not contain label '$label_filter')"
                skipped=$((skipped+1))
                continue
            fi
        fi

        set +e
        create_issue_from_file "$file" "$assignee" "$dry_run"
        local exit_code=$?
        set -e

        case $exit_code in
            0) created=$((created+1)) ;;
            1) skipped=$((skipped+1)) ;;
            2) failed=$((failed+1)) ;;
        esac
    done

    COUNTS["pass"]=$created
    COUNTS["skip"]=$skipped
    COUNTS["fail"]=$failed

    print_progress_bar
    print_summary
    print_signature

    local end_time=$(date +%s)
    echo -e "\n${WHITE}⏱ Completed in $((end_time - start_time)) seconds${NC}"

    if [[ $failed -gt 0 ]]; then
        echo -e "\n${RED}❌ Issue creation completed with ${failed} failure(s).${NC}"
        exit 1
    else
        echo -e "\n${GREEN}🎉 Successfully processed ${created} new issue(s).${NC}"
    fi
}

main "$@"
