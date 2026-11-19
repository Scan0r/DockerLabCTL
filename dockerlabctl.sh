#!/usr/bin/env bash
# Unofficial DockerLabs catalog, archive downloader, and local lab launcher.
set -Eeuo pipefail

readonly CATALOG_URL='https://dockerlabs.es/'
readonly DOWNLOAD_ROOT='https://gestion-maquinas.dockerlabs.es/dl'
readonly CACHE_TTL=86400
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dockerlabs-bash"
CACHE_FILE="$CACHE_DIR/catalog"
DEST_DIR="$HOME/DockerLabs"
COMMAND=''
QUERY=''
DIFFICULTY=''
CATEGORY=''
AUTHOR=''
COLOR=0
SHOW_DESCRIPTION=0
BOLD_DESCRIPTION=0
COMPLETED_FILTER=''
SORT_BY='id'
LIMIT=0
REFRESH=0
OVERWRITE=0
AS_JSON=0
ASSUME_YES=0
TEMP_DIR=''
PROGRESS_ARGS=()
PROGRESS_ACTION=''
PROGRESS_NAMES=()
COOKIE_VALUE=''
COOKIE_FILE=''
CSRF_VALUE=''
CSRF_FILE=''
PROGRESS_PUSH=0

usage() {
  cat <<'HELP'
DockerLabCTL — Bash catalog search, ZIP downloader, and local lab launcher

Usage: dockerlabctl COMMAND [OPTIONS]

Commands:
  deploy <Name|ID>             Deploy a locally available machine (offline)
  download <Name|ID>           Download and validate the machine ZIP
  info <Name|ID>               Show machine information
  link <Name|ID>               Print the direct archive URL
  list                         List all catalog machines
  local                        List downloaded and extracted local machines
  name <Text>                  Search only machine names (partial matches supported)
  progress                     Manage completion progress (see below)
  random                       Pick a random matching machine (does not download)
  remove <Name|ID>             Remove local machine archive/extracted files
  run <Name>                   Download if missing, then deploy the machine
  search <Text>                Search names, descriptions and catalog metadata

Progress commands:
  progress done <Name|All>           Mark completed locally (-p also updates website)
  progress fetch <Name|All>          Copy website completion status to local (website wins)
  progress list [local|remote|both]  List local, website, or compared progress
  progress push <Name|All>           Copy local completion status to website (local wins)
  progress undone <Name|All>         Remove completion locally (-p also updates website)

  <Name|All>: one or more machine names/IDs, or 'all' by itself.
  done/undone all target local machines; fetch/push all target the full catalog.

Catalog options (list/name/search/random):
  -a, --author TEXT        Filter by author
  -b, --bold               Bold recognized terms in descriptions (requires -t)
  -c, --category TEXT      Filter by category, e.g. 'Hacking Web'
  -r, --color              Colorize difficulty, category, completion and matches
  -p, --completed yes|no   Filter by local completion status
  -t, --description        Include machine descriptions
  -d, --difficulty VALUE   Filter: very easy, easy, medium, hard
  -l, --limit N            Maximum results (0 = all)
  -s, --sort FIELD         Sort: id, name, difficulty, category, author

  Short flags can be grouped: -rt, -brt, -rdhard (value-taking flag last).

Progress options:
  -p, --push   Push done/undone changes to the website profile

Other options:
      --cookie TEXT        Cookie header value (avoid exposing in shell history)
      --cookie-file FILE   Read Cookie header from a private file
      --csrf TOKEN         Override automatically detected CSRF token
      --csrf-file FILE     Read CSRF override from a private file
  -h, --help               Show this help message
      --json               JSON output for catalog commands
  -o, --output DIR         Local storage directory (default: ~/DockerLabs)
      --overwrite          Replace an existing archive after a valid download
      --refresh            Refresh catalog, bypassing the 24-hour cache
  -y, --yes                Skip supported confirmation prompts

Examples:
  dockerlabctl deploy Analyst
  dockerlabctl download Analyst -o ~/Labs/DockerLabs
  dockerlabctl info Analyst
  dockerlabctl link Analyst
  dockerlabctl list -d easy -c 'Hacking Web' -p no -r
  dockerlabctl list -t --sort difficulty
  dockerlabctl local
  dockerlabctl name Analyst -r
  dockerlabctl progress done Analyst
  dockerlabctl progress done Analyst -p --cookie-file ~/.config/dockerlabs/cookie
  dockerlabctl progress done all
  dockerlabctl progress fetch Analyst
  dockerlabctl progress fetch all --yes
  dockerlabctl progress list
  dockerlabctl progress list remote
  dockerlabctl progress list both
  dockerlabctl progress push Analyst
  dockerlabctl progress undone Analyst
  dockerlabctl progress undone Analyst -p
  dockerlabctl progress undone all
  dockerlabctl random -d hard -p no
  dockerlabctl remove Analyst --yes
  dockerlabctl run Analyst --yes
  dockerlabctl search Analyst -rt

Downloads use https://gestion-maquinas.dockerlabs.es/dl/<archive>.zip
The archive name is automatically derived from the machine name.
HELP
}

error() { printf 'Error: %s\n' "$*" >&2; }
warn()  { printf 'Warning: %s\n' "$*" >&2; }
die()   { error "$*"; exit 2; }
need_value() { [[ $# -ge 2 && -n "${2:-}" ]] || die "Missing value for $1"; }

while (( $# )); do
  case "$1" in
    list|name|search|info|link|download|random|local|deploy|run|remove|progress)
      if [[ -z $COMMAND ]]; then COMMAND="$1"; elif [[ $COMMAND == progress ]]; then PROGRESS_ARGS+=("$1"); else die 'Only one command is allowed'; fi
      shift ;;
    -d|--difficulty) need_value "$@"; DIFFICULTY="$2"; shift 2 ;;
    -c|--category)  need_value "$@"; CATEGORY="$2"; shift 2 ;;
    -r|--color|--colour) COLOR=1; shift ;;
    -t|--description) SHOW_DESCRIPTION=1; shift ;;
    -b|--bold) BOLD_DESCRIPTION=1; shift ;;
    -p) if [[ $COMMAND == progress ]]; then PROGRESS_PUSH=1; shift; else need_value "$@"; COMPLETED_FILTER="${2,,}"; shift 2; fi ;;
    --push) PROGRESS_PUSH=1; shift ;;
    --completed) need_value "$@"; COMPLETED_FILTER="${2,,}"; shift 2 ;;
    -a|--author)         need_value "$@"; AUTHOR="$2"; shift 2 ;;
    -l|--limit)         need_value "$@"; LIMIT="$2"; shift 2 ;;
    -s) need_value "$@"; SORT_BY="$2"; shift 2 ;;
    --sort) need_value "$@"; SORT_BY="$2"; shift 2 ;;
    -o|--output)      need_value "$@"; DEST_DIR="$2"; shift 2 ;;
    --refresh) REFRESH=1; shift ;;
    --overwrite) OVERWRITE=1; shift ;;
    --json) AS_JSON=1; shift ;;
    --cookie) need_value "$@"; COOKIE_VALUE="$2"; shift 2 ;;
    --cookie-file) need_value "$@"; COOKIE_FILE="$2"; shift 2 ;;
    --csrf) need_value "$@"; CSRF_VALUE="$2"; shift 2 ;;
    --csrf-file) need_value "$@"; CSRF_FILE="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while (( $# )); do if [[ $COMMAND == progress ]]; then PROGRESS_ARGS+=("$1"); else QUERY="${QUERY:+$QUERY }$1"; fi; shift; done ;;
    # Expand grouped short options (e.g. -rt, -brt, -rtdmedium).
    # Options that take values must be last in the group; their remainder is
    # the value (e.g. -rdhard = -r -d hard). Standalone -p under progress
    # is a switch, whereas -p under catalog commands expects yes/no.
    -[a-zA-Z]?*)
      short_group="${1#-}"
      shift
      short_args=()
      while [[ -n $short_group ]]; do
        short_flag="${short_group:0:1}"
        short_group="${short_group:1}"
        case "$short_flag" in
          r|t|b|y|h) short_args+=("-$short_flag") ;;
          p)
            short_args+=(-p)
            if [[ $COMMAND != progress ]]; then
              if [[ -n $short_group ]]; then short_args+=("$short_group"); short_group=''; fi
              break
            fi
            ;;
          d|c|a|l|s|o)
            short_args+=("-$short_flag")
            if [[ -n $short_group ]]; then short_args+=("$short_group"); short_group=''; fi
            break
            ;;
          *) die "Unknown option: -$short_flag" ;;
        esac
      done
      set -- "${short_args[@]}" "$@"
      ;;
    -*) die "Unknown option: $1" ;;
    *) if [[ $COMMAND == progress ]]; then PROGRESS_ARGS+=("$1"); else QUERY="${QUERY:+$QUERY }$1"; fi; shift ;;
  esac
done

[[ -n $COMMAND ]] || { usage; exit 1; }
[[ $LIMIT =~ ^[0-9]+$ ]] || die '--limit must be an integer >= 0'
case "$COMMAND" in
  list|name|search|random) CATALOG_COMMAND=1 ;;
  *) CATALOG_COMMAND=0 ;;
esac
[[ $PROGRESS_PUSH == 0 || $COMMAND == progress ]] || die "--push/-p only applies to progress done/undone"
[[ $CATALOG_COMMAND == 1 || $SORT_BY == id ]] || die '--sort only applies to list/name/search/random'
[[ $COLOR == 0 || $CATALOG_COMMAND == 1 ]] || die '--color/-r only applies to list/name/search/random'
[[ $SHOW_DESCRIPTION == 0 || $CATALOG_COMMAND == 1 ]] || die '--description/-t only applies to list/name/search/random'
[[ $BOLD_DESCRIPTION == 0 || $CATALOG_COMMAND == 1 ]] || die '--bold/-b only applies to list/name/search/random'
[[ $BOLD_DESCRIPTION == 0 || $SHOW_DESCRIPTION == 1 ]] || die '--bold/-b requires --description/-t'
[[ -z $COMPLETED_FILTER || $CATALOG_COMMAND == 1 ]] || die '--completed/-p only applies to list/name/search/random'
[[ $LIMIT == 0 || $CATALOG_COMMAND == 1 ]] || die '--limit/-l only applies to list/name/search/random'
case "$COMPLETED_FILTER" in ''|yes|no) ;; *) die '--completed/-p must be yes or no' ;; esac
case "$SORT_BY" in id|name|difficulty|category|author) ;; *) die '--sort must be one of: id, name, difficulty, category, author' ;; esac
[[ $ASSUME_YES == 0 || $COMMAND == deploy || $COMMAND == run || $COMMAND == remove || $COMMAND == progress ]] || die '--yes is only supported by deploy/run/remove'
[[ $COMMAND == progress || ( -z $COOKIE_VALUE && -z $COOKIE_FILE && -z $CSRF_VALUE && -z $CSRF_FILE ) ]] || die 'Authentication options only apply to progress'
[[ -z $COOKIE_VALUE || -z $COOKIE_FILE ]] || die 'Choose --cookie or --cookie-file, not both'
[[ -z $CSRF_VALUE || -z $CSRF_FILE ]] || die 'Choose --csrf or --csrf-file, not both'
[[ $AS_JSON == 0 || $COMMAND == list || $COMMAND == name || $COMMAND == search || $COMMAND == random ]] || die '--json is only supported by list/search/random'
case "$COMMAND" in
  info|link|download|deploy|run|remove) [[ -n $QUERY ]] || die "$COMMAND requires a machine name or ID" ;;
  progress)
    (( ${#PROGRESS_ARGS[@]} >= 1 )) || die 'Usage: progress {done NAME...|undone NAME...|list}'
    PROGRESS_ACTION="${PROGRESS_ARGS[0]}"
    PROGRESS_NAMES=("${PROGRESS_ARGS[@]:1}")
    [[ $PROGRESS_PUSH == 0 || $PROGRESS_ACTION == done || $PROGRESS_ACTION == undone ]] || die "--push/-p only applies to progress done/undone"
    case "$PROGRESS_ACTION" in
      done|undone)
        (( ${#PROGRESS_NAMES[@]} >= 1 )) || die "progress $PROGRESS_ACTION requires one or more machine names"
        if [[ ${PROGRESS_NAMES[0]} == all && ${#PROGRESS_NAMES[@]} -ne 1 ]]; then die "Use 'all' alone, not alongside machine names"; fi
        ;;
      list)
        (( ${#PROGRESS_NAMES[@]} <= 1 )) || die 'Usage: progress list [local|remote|both]'
        case "${PROGRESS_NAMES[0]:-local}" in
          local|remote|both) ;;
          *) die 'Usage: progress list [local|remote|both]' ;;
        esac
        ;;
      fetch|push)
        (( ${#PROGRESS_NAMES[@]} > 0 )) || die "Usage: progress $PROGRESS_ACTION NAME...|all"
        if [[ ${PROGRESS_NAMES[0]} == all && ${#PROGRESS_NAMES[@]} -ne 1 ]]; then die "Use all alone, not alongside machine names"; fi
        ;;
      *) die 'Usage: progress {done NAME...|undone NAME...|list|fetch NAME...|all|push NAME...|all}' ;;
    esac
    ;;
  name|search) [[ -n $QUERY || -n $DIFFICULTY || -n $CATEGORY || -n $AUTHOR ]] || die "$COMMAND requires text or at least one filter" ;;
  list|random|local) [[ -z $QUERY ]] || die "The $COMMAND command does not accept a name; use search" ;;
esac

# Local commands must not need the online catalog or its dependencies.
# The run command loads the catalog only when no matching local machine exists.
require_online_dependencies() {
  local bin
  for bin in curl jq perl file iconv; do
    command -v "$bin" >/dev/null 2>&1 || die "Missing dependency: $bin"
  done
  perl -MHTML::Parser -MHTML::Entities -MJSON::PP -e 'exit 0' >/dev/null 2>&1 || \
    die 'Missing Perl HTML::Parser / HTML::Entities modules (install libhtml-parser-perl)'
  mkdir -p -- "$CACHE_DIR" || die "Cannot create cache directory: $CACHE_DIR"
}

TEMP_DIR="$(mktemp -d)" || die 'Cannot create temporary directory'
trap 'rm -rf -- "$TEMP_DIR"' EXIT
if [[ $COMMAND != local && $COMMAND != deploy && $COMMAND != run && $COMMAND != remove  ]]; then
  require_online_dependencies
fi

fetch_page() {
  local url="$1" dest="$2"
  curl --fail --location --silent --show-error --retry 2 \
    --connect-timeout 12 --max-time 75 --proto '=https' --proto-redir '=https' \
    --user-agent 'DockerLabs-Bash-CLI/2.0' --url "$url" --output "$dest"
}

parse_catalog() {
  perl - "$1" <<'PERL'
use strict;
use warnings;
use utf8;
use HTML::Parser;
use HTML::Entities qw(decode_entities);
use JSON::PP qw(decode_json);
use Encode qw(encode);
my $path = shift @ARGV;
open my $f, '<:encoding(UTF-8)', $path or die "Cannot read catalog HTML: $!\n";
local $/;
my $html = <$f>;
my (@machines, %seen, $card, $depth, $capture);
sub clean {
    my $s = shift // '';
    $s =~ s/[\t\r\n]+/ /g;
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}
sub description_from_args {
    my (@quoted) = @_;
    my @candidates;
    for my $quoted (@quoted) {
        my $value = eval { decode_json(encode('UTF-8', $quoted)) };
        next unless defined $value && !ref($value);
        $value = clean($value);
        # URLs and date/metadata fields are not machine descriptions.
        next if $value =~ m{^https?://}i;
        next if $value =~ /^\d{1,2}[\/-]\d{1,2}[\/-]\d{2,4}$/;
        next unless length($value) >= 35 && scalar(split /\s+/, $value) >= 5;
        # If a URL is embedded alongside prose, keep the prose only.
        $value =~ s{https?://\S+}{}gi;
        $value = clean($value);
        next unless length($value) >= 30;
        push @candidates, $value;
    }
    return '' unless @candidates;
    @candidates = sort { length($b) <=> length($a) } @candidates;
    return $candidates[0];
}
sub description_from_button {
    my ($js) = @_;
    # DockerLabs uses the JavaScript function `descripcion` for descriptions.
    # Keep this upstream identifier unchanged; it is not a CLI command.
    # Decode the second JavaScript string as JSON so \uXXXX escapes become UTF-8.
    return '' unless $js =~ /\bdescripcion\s*\(\s*("(?:\\.|[^"\\])*")\s*,\s*("(?:\\.|[^"\\])*")/s;
    my $quoted = $2;
    my $value = eval { decode_json(encode('UTF-8', $quoted)) };
    return '' unless defined $value && !ref($value);
    $value = clean($value);
    return '' if $value =~ m{^https?://}i;
    return $value;
}
my $parser = HTML::Parser->new(
  api_version => 3,
  start_h => [sub {
    my ($tag, $attr) = @_;
    if (!$card && $tag eq 'div' && ($attr->{'data-id'} // '') =~ /^\d+$/
        && ($attr->{class} // '') =~ /(?:^|\s)(?:maquina-item|item)(?:\s|$)/) {
        $card = {
            id => 0 + $attr->{'data-id'}, name => '', difficulty => '',
            category => clean(decode_entities($attr->{'data-category'} // '')),
            author => '', date => '', description => '', search_text => ''
        };
        $depth = 1;
        my $js = decode_entities($attr->{onclick} // '');
        # Index every card attribute and the complete onclick payload. The
        # description is embedded in presentacion() on some catalog versions,
        # and relying on a fixed number of quoted arguments silently dropped
        # descriptions for cards whose argument list differed.
        $card->{search_text} .= ' ' . join(' ', map { $_ // '' } values %$attr);
        $card->{search_text} .= ' ' . $js;
        if ($js =~ /presentacion\s*\(/) {
            my @str = ($js =~ /("(?:\\.|[^"\\])*")/g);
            if (@str >= 4) {
                eval { $card->{author} = clean(decode_json(encode('UTF-8', $str[3]))); 1 };
                eval { $card->{date} = clean(decode_json(encode('UTF-8', $str[-1]))); 1 } if @str >= 6;
                $card->{description} = description_from_args(@str);
            }
        }
        return;
    }
    return unless $card;
    $depth++ if $tag eq 'div';
    # Descriptions are commonly attached to the nested "Descripción" button,
    # not to the outer machine card. Index attributes from every descendant.
    my $attrs = join(' ', map { $_ // '' } values %$attr);
    $attrs = decode_entities($attrs);
    $card->{search_text} .= ' ' . $attrs if length $attrs;
    my $nested_js = decode_entities($attr->{onclick} // '');
    if (length $nested_js) {
        $card->{search_text} .= ' ' . $nested_js;
        # Also decode JSON-style quoted arguments so escaped/encoded text is
        # searchable independently of its JavaScript representation.
        while ($nested_js =~ /("(?:\\.|[^"\\])*")/g) {
            my $quoted = $1;
            my $decoded = eval { decode_json(encode('UTF-8', $quoted)) };
            $card->{search_text} .= ' ' . $decoded if defined $decoded && !ref($decoded);
        }
        if ($nested_js =~ /descripcion\s*\(/) {
            my $candidate = description_from_button($nested_js);
            $card->{description} = $candidate if length $candidate;
        }
        if ($nested_js =~ /presentacion\s*\(/) {
            my @str = ($nested_js =~ /("(?:\\.|[^"\\])*")/g);
            my $candidate = description_from_args(@str);
            $card->{description} = $candidate if length($candidate) > length($card->{description} // '');
        }
    }
    if ($tag eq 'strong' && $card->{name} eq '') { $capture = 'name' }
    if ($tag eq 'span' && ($attr->{class} // '') =~ /(?:^|\s)(?:etiqueta|badge)(?:\s|$)/) {
        $capture = 'difficulty';
    }
  }, 'tagname, attr'],
  text_h => [sub {
    my $text = shift;
    if ($card) {
        $card->{search_text} .= ' ' . $text;
        $card->{$capture} .= $text if $capture;
    }
  }, 'dtext'],
  end_h => [sub {
    my $tag = shift;
    return unless $card;
    $capture = undef if ($tag eq 'strong' && ($capture // '') eq 'name')
                    || ($tag eq 'span' && ($capture // '') eq 'difficulty');
    if ($tag eq 'div') {
        $depth--;
        if ($depth == 0) {
            $card->{name} = clean($card->{name});
            $card->{difficulty} = clean($card->{difficulty});
            $card->{description} = clean($card->{description});
            $card->{search_text} = clean($card->{search_text});
            my %english = (
              'muy fácil' => 'Very Easy', 'muy facil' => 'Very Easy',
              'fácil' => 'Easy', 'facil' => 'Easy',
              'medio' => 'Medium',
              'difícil' => 'Hard', 'dificil' => 'Hard'
            );
            $card->{difficulty} = $english{lc($card->{difficulty})} // $card->{difficulty};
            push @machines, $card if $card->{name} ne '' && $card->{difficulty} ne '' && !$seen{$card->{id}}++;
            undef $card;
            undef $capture;
        }
    }
  }, 'tagname'],
);
$parser->parse($html);
$parser->eof;
die "No machine entries found (DockerLabs page structure may have changed)\n" unless @machines;
binmode STDOUT, ':raw';
print JSON::PP->new->utf8->encode({ updated_at => time(), machines => \@machines });
PERL
}

load_catalog() {
  local now age
  now="$(date +%s)"
  if (( REFRESH == 0 )) && [[ -s $CACHE_FILE ]]; then
    age=$(( now - $(stat -c %Y -- "$CACHE_FILE") ))
    if (( age >= 0 && age < CACHE_TTL )) && jq -e '.machines | type == "array" and length > 0' "$CACHE_FILE" >/dev/null 2>&1; then
      return 0
    fi
  fi
  if ! fetch_page "$CATALOG_URL" "$TEMP_DIR/index.html"; then
    if (( REFRESH == 0 )) && [[ -s $CACHE_FILE ]] && jq -e '.machines | length > 0' "$CACHE_FILE" >/dev/null 2>&1; then
      warn 'Cannot refresh catalog; using the previous cache.'
      return 0
    fi
    die 'Could not retrieve the catalog from dockerlabs.es'
  fi
  if ! parse_catalog "$TEMP_DIR/index.html" > "$TEMP_DIR/catalog.json"; then
    die 'Unable to parse the DockerLabs catalog'
  fi
  mv -- "$TEMP_DIR/catalog.json" "$CACHE_FILE"
}

# Normalize upstream difficulty labels and strip diacritics for searching.
JQ_NORM='def norm: gsub("[áàäâÁÀÄÂ]";"a") | gsub("[éèëêÉÈËÊ]";"e") | gsub("[íìïîÍÌÏÎ]";"i") | gsub("[óòöôÓÒÖÔ]";"o") | gsub("[úùüûÚÙÜÛ]";"u") | gsub("[ñÑ]";"n") | ascii_downcase | gsub("^\\s+|\\s+$";""); def difficulty_key: norm | if . == "very easy" or . == "muy facil" then "very easy" elif . == "facil" or . == "easy" then "easy" elif . == "medio" or . == "medium" then "medium" elif . == "dificil" or . == "hard" then "hard" else . end;'

filter_catalog() {
  local match_expr
  if [[ $COMMAND == search ]]; then
    # Broad search across name, description and available catalog metadata.
    match_expr='([.name, .description, .category, .author, .difficulty, .date, .search_text] | map(. // "") | join(" ") | norm | contains($q | norm))'
  else
    # `name` is deliberately strict: only the machine name is searched.
    match_expr='(.name | norm | contains($q | norm))'
  fi
  jq -c --arg q "$QUERY" --arg d "$DIFFICULTY" --arg c "$CATEGORY" --arg a "$AUTHOR" --arg sort "$SORT_BY" --arg command "$COMMAND" \
    "$JQ_NORM [ .machines[] | select((\$q == \"\" or $match_expr) and (\$d == \"\" or (.difficulty | difficulty_key) == (\$d | difficulty_key)) and (\$c == \"\" or (.category | norm | contains(\$c | norm))) and (\$a == \"\" or (.author | norm | contains(\$a | norm)))) ] | if \$sort == \"id\" then sort_by(.id) elif \$sort == \"name\" then sort_by(.name | norm) elif \$sort == \"difficulty\" then sort_by((.difficulty | difficulty_key | if . == \"very easy\" then 0 elif . == \"easy\" then 1 elif . == \"medium\" then 2 elif . == \"hard\" then 3 else 4 end), (.difficulty | norm)) elif \$sort == \"category\" then sort_by(.category | norm) else sort_by(.author | norm) end" "$CACHE_FILE"

}

# Apply completion status consistently to every catalog-query command.
filter_completed() {
  local items="$1" progress_file="$DEST_DIR/.dockerlabs-done" record machine_name stem is_done
  [[ -n $COMPLETED_FILTER ]] || { printf '%s\n' "$items"; return 0; }
  : > "$TEMP_DIR/completed-filter.jsonl"
  while IFS= read -r record; do
    machine_name="$(jq -r '.name' <<< "$record")"
    stem="$(archive_slug "$machine_name")"
    is_done=0
    [[ -f $progress_file ]] && grep -Fqx -- "$stem" "$progress_file" && is_done=1
    if [[ $COMPLETED_FILTER == yes && $is_done == 1 ]] || [[ $COMPLETED_FILTER == no && $is_done == 0 ]]; then
      printf '%s\n' "$record" >> "$TEMP_DIR/completed-filter.jsonl"
    fi
  done < <(jq -c '.[]' <<< "$items")
  jq -s '.' "$TEMP_DIR/completed-filter.jsonl"
}

clip_description() {
  local value="$1" width="$2" length
  length="$(printf '%s' "$value" | wc -m)"
  if (( length > width )); then
    if (( width > 1 )); then printf '%s…' "$(printf '%s' "$value" | cut -c1-$((width - 1)))"; else printf '…'; fi
  else printf '%s' "$value"; fi
}

# Bold rules: dictionary terms always; words after the first when initially uppercase;
# first word only when entirely uppercase. Matching is Unicode-aware and dictionary matching is case-insensitive.
format_description() {
  local clipped
  clipped="$(clip_description "$1" "$2")"
  if (( BOLD_DESCRIPTION )); then
    printf '%s' "$clipped" | perl -CSDA -pe '
      BEGIN {
        $word_index = 0;
        %bold = map { $_ => 1 } qw(
          sqli sql sqlinjection injection nosql xss xxe xinclude xssdom
          ssti templateinjection server-side-template-injection
          ssrf csrf csrf-token cors csp hsts
          rce commandinjection command-injection oscommandinjection
          lfi rfi inclusion fileinclusion localfileinclusion remotefileinclusion
          pathtraversal directorytraversal traversal
          idor bola bfla massassignment brokenobjectlevelauthorization
          brokenfunctionlevelauthorization brokenaccesscontrol
          jwt jwk jws jwe oauth oauth2 oidc saml
          auth authentication authorization session fixation
          deserialization insecuredeserialization pickle
          ldapinjection xpathinjection nosqlinjection
          xxe xml externalentity entityexpansion
          waf bypass wafbypass
          openredirect redirect
          ssrfxxe prototypepollution prototype-pollution
          racecondition race-condition businesslogic business-logic
          fileupload unrestrictedfileupload
          passwordreset accounttakeover mfa 2fa
          cve api rest graphql websocket
          rcecodeexecution codeinjection eval
          php typejuggling type-juggling
        );
      }
      s{(CVE-\d{4}-\d+)|([\p{L}][\p{L}\p{M}\x{27}\x{2019}\x{2011}-]*)}{
        my $word = defined($1) ? $1 : $2;
        my $is_cve = defined($1);
        my $is_first = ($word_index++ == 0);
        my $is_dictionary_term = $is_cve || exists $bold{lc $word};
        # CVE identifiers are treated as one complete token, including year and ID.
        # First token: require every letter to be uppercase (e.g. SQLI, XXE).
        # Remaining tokens: an uppercase initial is enough (e.g. Zabbixploit, Medio).
        my $is_first_all_caps = $is_first && $word =~ /^\p{Lu}+$/u;
        my $is_later_capitalized = !$is_first && $word =~ /^\p{Lu}/u;
        ($is_dictionary_term || $is_first_all_caps || $is_later_capitalized)
          ? "\e[1m$word\e[0m" : $word;
      }ge;
    '
  else
    printf '%s' "$clipped"
  fi
}

# Print a fixed-width cell with ANSI color without disturbing column alignment.
print_colored_cell() {
  local width="$1" color="$2" value="$3"
  if (( COLOR )); then
    printf '\033[%sm%-*.*s\033[0m' "$color" "$width" "$width" "$value"
  else
    printf '%-*.*s' "$width" "$width" "$value"
  fi
}

difficulty_color() {
  # 256-color palette: deliberately high contrast between difficulty levels.
  case "${1,,}" in
    'very easy'|'muy fácil'|'muy facil') printf '38;5;51' ;;  # bright cyan
    easy|fácil|facil) printf '38;5;82' ;;                    # vivid green
    medium|medio) printf '38;5;214' ;;                      # orange
    hard|difícil|dificil) printf '38;5;196' ;;               # bright red
    *) printf '38;5;250' ;;
  esac
}

category_color() {
  # Separate hues for categories; avoid reusing the difficulty palette.
  local value="${1,,}"
  case "$value" in
    *'hacking web'*) printf '38;5;201' ;;                    # magenta
    *'hacking api'*) printf '38;5;39' ;;                     # blue
    *'hacking redes'*|*'redes'*) printf '38;5;226' ;;        # yellow
    *'hacking sistemas'*|*'sistemas'*) printf '38;5;208' ;; # deep orange
    *'hacking cloud'*|*'cloud'*) printf '38;5;93' ;;        # purple
    *) printf '38;5;245' ;;
  esac
}

print_table() {
  local items="$1" visible count matched term_width desc_width
  count="$(jq 'length' <<< "$items")"
  if (( LIMIT > 0 )); then visible="$(jq -c --argjson n "$LIMIT" '.[0:$n]' <<< "$items")"; else visible="$items"; fi
  term_width=120
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then term_width="$(tput cols 2>/dev/null || printf '120')"; fi
  [[ $term_width =~ ^[0-9]+$ ]] || term_width=120
  desc_width=$((term_width - 105)); (( desc_width < 1 )) && desc_width=1

  if [[ $COMMAND == list ]]; then
    local progress_file="$DEST_DIR/.dockerlabs-done" list_stem completed_status description
    if (( SHOW_DESCRIPTION )); then
      printf '\n%5s  %-20s %-10s %-9s %-16s %-14s %s\n' 'ID' 'NAME' 'DIFFICULTY' 'COMPLETED' 'CATEGORY' 'AUTHOR' 'DESCRIPTION'
      printf '%s\n' '------------------------------------------------------------------------------------------------------------------------------------------------'
    else
      printf '\n%5s  %-20s %-10s %-9s %-16s %-14s\n' 'ID' 'NAME' 'DIFFICULTY' 'COMPLETED' 'CATEGORY' 'AUTHOR'
      printf '%s\n' '-----------------------------------------------------------------------------------------------'
    fi
    count=0
    while IFS=$'\t' read -r id name diff cat author description; do
      list_stem="$(archive_slug "$name")"
      completed_status='No'
      if [[ -f $progress_file ]] && grep -Fqx -- "$list_stem" "$progress_file"; then completed_status='YES'; fi
      if [[ $COMPLETED_FILTER == yes && $completed_status != YES ]]; then continue; fi
      if [[ $COMPLETED_FILTER == no && $completed_status == YES ]]; then continue; fi
      if (( LIMIT > 0 && count >= LIMIT )); then break; fi
      ((count+=1))
      printf '%5s  %-20.20s ' "$id" "$name"
      print_colored_cell 10 "$(difficulty_color "$diff")" "$diff"; printf ' '
      if [[ $completed_status == YES ]]; then print_colored_cell 9 '38;5;46' "$completed_status"; else print_colored_cell 9 '38;5;245' "$completed_status"; fi
      printf ' '; print_colored_cell 16 "$(category_color "$cat")" "$cat"
      if (( SHOW_DESCRIPTION )); then
        printf ' %-14.14s %s\n' "$author" "$(format_description "${description:-—}" "$((term_width - 89 > 1 ? term_width - 89 : 1))")"
      else printf ' %-14.14s\n' "$author"; fi
    done < <(jq -r '.[] | [.id, .name, .difficulty, (if .category == "" then "—" else .category end), (if .author == "" then "—" else .author end), (.description // "")] | @tsv' <<< "$visible")

  elif [[ $COMMAND == search && -n $QUERY ]]; then
    if (( SHOW_DESCRIPTION )); then
      printf '\n%5s  %-22s %-10s %-17s %-14s %-17s %s\n' 'ID' 'NAME' 'DIFFICULTY' 'CATEGORY' 'AUTHOR' 'MATCHED IN' 'DESCRIPTION'
      printf '%s\n' '------------------------------------------------------------------------------------------------------------------------------------------------'
    else
      printf '\n%5s  %-27s %-12s %-23s %-18s %s\n' 'ID' 'NAME' 'DIFFICULTY' 'CATEGORY' 'AUTHOR' 'MATCHED IN'
      printf '%s\n' '---------------------------------------------------------------------------------------------------------------'
    fi
    while IFS=$'\t' read -r id name diff cat author matched description; do
      if (( SHOW_DESCRIPTION )); then
        printf '%5s  %-22.22s ' "$id" "$name"
        print_colored_cell 10 "$(difficulty_color "$diff")" "$diff"; printf ' '
        print_colored_cell 17 "$(category_color "$cat")" "$cat"
        printf ' %-14.14s ' "$author"
        print_colored_cell 17 '38;5;220' "$matched"
        printf ' %s\n' "$(format_description "$description" "$desc_width")"
      else
        printf '%5s  %-27.27s ' "$id" "$name"
        print_colored_cell 12 "$(difficulty_color "$diff")" "$diff"; printf ' '
        print_colored_cell 23 "$(category_color "$cat")" "$cat"
        printf ' %-18.18s ' "$author"
        print_colored_cell 18 '38;5;220' "$matched"
        printf '\n'
      fi
    done < <(jq -r --arg q "$QUERY" "$JQ_NORM .[] | [.id, .name, .difficulty, (if .category == \"\" then \"—\" else .category end), (if .author == \"\" then \"—\" else .author end), ([ [\"name\", .name], [\"text\", .date], [\"categ\", .category], [\"auth\", .author], [\"diff\", .difficulty], [\"text\", .search_text], [\"desc\", .description] ] | map(select((.[1] // \"\") | norm | contains(\$q | norm)) | .[0]) | unique | join(\", \")), (.description // \"\")] | @tsv" <<< "$visible")

  else
    if (( SHOW_DESCRIPTION )); then
      printf '\n%5s  %-22s %-10s %-17s %-14s %s\n' 'ID' 'NAME' 'DIFFICULTY' 'CATEGORY' 'AUTHOR' 'DESCRIPTION'
      printf '%s\n' '---------------------------------------------------------------------------------------------------------------'
    else
      printf '\n%5s  %-27s %-12s %-23s %s\n' 'ID' 'NAME' 'DIFFICULTY' 'CATEGORY' 'AUTHOR'
      printf '%s\n' '---------------------------------------------------------------------------------------------'
    fi
    while IFS=$'\t' read -r id name diff cat author description; do
      if (( SHOW_DESCRIPTION )); then
        printf '%5s  %-22.22s ' "$id" "$name"
        print_colored_cell 10 "$(difficulty_color "$diff")" "$diff"; printf ' '
        print_colored_cell 17 "$(category_color "$cat")" "$cat"
        printf ' %-14.14s %s\n' "$author" "$(format_description "$description" "$desc_width")"
      else
        printf '%5s  %-27.27s ' "$id" "$name"
        print_colored_cell 12 "$(difficulty_color "$diff")" "$diff"; printf ' '
        print_colored_cell 23 "$(category_color "$cat")" "$cat"
        printf ' %.26s\n' "$author"
      fi
    done < <(jq -r '.[] | [.id, .name, .difficulty, (if .category == "" then "—" else .category end), (if .author == "" then "—" else .author end), (.description // "")] | @tsv' <<< "$visible")
  fi
  printf '\nMatches: %s' "$count"
  if (( LIMIT > 0 )) && [[ $COMMAND != list ]]; then printf ' (shown: %s)' "$(jq 'length' <<< "$visible")"; fi
  printf '\n'
}

select_machine() {
  local exact matches count
  exact="$(jq -c --arg q "$QUERY" "$JQ_NORM [ .machines[] | select((.name | norm) == (\$q | norm) or ((.id | tostring) == \$q)) ]" "$CACHE_FILE")"
  count="$(jq 'length' <<< "$exact")"
  if (( count == 1 )); then jq -c '.[0]' <<< "$exact"; return; fi
  (( count == 0 )) || die 'Multiple machines have that exact name; use a numeric ID'
  matches="$(jq -c --arg q "$QUERY" "$JQ_NORM [ .machines[] | select(.name | norm | contains(\$q | norm)) ]" "$CACHE_FILE")"
  count="$(jq 'length' <<< "$matches")"
  if (( count == 1 )); then jq -c '.[0]' <<< "$matches"; return; fi
  if (( count == 0 )); then die "Machine not found: $QUERY (try: dockerlabctl search '$QUERY')"; fi
  print_table "$matches" >&2
  die "Ambiguous name: $QUERY (use the complete name or numeric ID)"
}

# Archive filenames are typically the lowercase name without spaces.
# Archive naming is automatic; there is no user-supplied filename override.
archive_slug() {
  local name="$1" stem
  stem="$(printf '%s' "$name" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null | \
    tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+//g')" || true
  [[ $stem =~ ^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$ ]] || die "Invalid archive name '$stem' derived from machine name"
  [[ $stem != *..* ]] || die 'Archive name must not contain consecutive dots'
  [[ ${#stem} -le 120 ]] || die 'Archive name is too long'
  printf '%s' "$stem"
}

archive_url() {
  local slug="$1"
  printf '%s/%s.zip' "$DOWNLOAD_ROOT" "$slug"
}

run_download() {
  local machine="$1" id name diff slug url dest part mime
  id="$(jq -r '.id' <<< "$machine")"
  name="$(jq -r '.name' <<< "$machine")"
  diff="$(jq -r '.difficulty' <<< "$machine")"
  slug="$(archive_slug "$name")"
  url="$(archive_url "$slug")"
  if [[ $COMMAND == link ]]; then
    printf '%s\n' "$url"
    return 0
  fi
  mkdir -p -- "$DEST_DIR" || die "Cannot create download directory: $DEST_DIR"
  dest="$DEST_DIR/$slug.zip"
  part="$DEST_DIR/$slug.zip.part"
  if [[ -e $dest && $OVERWRITE == 0 ]]; then
    die "File already exists: $dest (use --overwrite to replace)"
  fi
  printf 'Machine: %s (ID: %s; difficulty: %s)\n' "$name" "$id" "$diff"
  printf 'URL: %s\nDestination: %s\n' "$url" "$dest"
  # Download into a .part file; do not replace existing ZIPs until validation.
  local -a resume=()
  [[ -s $part ]] && resume=(--continue-at -)
  if ! curl --fail --location --show-error --progress-bar --retry 2 \
    --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
    --max-filesize 6442450944 --proto '=https' --proto-redir '=https' \
    --user-agent 'DockerLabs-Bash-CLI/2.0' "${resume[@]}" \
    --url "$url" --output "$part"; then
    warn 'Download failed. The partial file (if any) is kept for resuming.'
    return 3
  fi
  [[ -s $part ]] || { rm -f -- "$part"; die 'The server returned an empty file'; }
  mime="$(file -b --mime-type -- "$part")"
  if [[ $mime != application/zip && $mime != application/x-zip* && $mime != application/octet-stream ]]; then
    rm -f -- "$part"
    die "Response is not a ZIP archive (MIME: $mime); discarded"
  fi
  # A quick ZIP signature check also handles octet-stream responses.
  if [[ "$(od -An -tx1 -N4 -- "$part" | tr -d ' \n')" != 504b0304 && \
        "$(od -An -tx1 -N4 -- "$part" | tr -d ' \n')" != 504b0506 ]]; then
    rm -f -- "$part"
    die 'Response does not have a valid ZIP signature; discarded'
  fi
  # Check the ZIP central directory without extracting or asking for passwords.
  # Unlike "unzip -t", this also accepts password-protected DockerLabs archives.
  if command -v unzip >/dev/null 2>&1 && ! unzip -Z -1 "$part" >/dev/null 2>&1; then
    rm -f -- "$part"
    die 'ZIP structure check failed; discarded'
  fi
  mv -f -- "$part" "$dest"
  printf 'Downloaded successfully: %s\n' "$dest"
  printf 'SHA256: '
  sha256sum -- "$dest" | cut -d' ' -f1
  if [[ $COMMAND == download ]]; then
    printf 'No archive is automatically extracted or executed.\n'
  fi
}


# Enumerate only top-level ZIP files and machine directories under DEST_DIR.
# A directory is considered deployable when it contains auto_deploy.sh.
local_machine_stems() {
  local path stem
  local -A seen=()
  shopt -s nullglob
  for path in "$DEST_DIR"/*.zip; do
    [[ -f $path && ! -L $path ]] || continue
    stem="${path##*/}"; stem="${stem%.zip}"
    seen["$stem"]=1
  done
  for path in "$DEST_DIR"/*/; do
    [[ -d $path && ! -L $path ]] || continue
    if [[ -n $(find "$path" -type f -name auto_deploy.sh -print -quit) ]]; then
      stem="${path%/}"; stem="${stem##*/}"
      seen["$stem"]=1
    fi
  done
  if [[ -f $DEST_DIR/auto_deploy.sh && ! -L $DEST_DIR/auto_deploy.sh ]]; then
    for path in "$DEST_DIR"/*.tar; do
      [[ -f $path && ! -L $path ]] || continue
      stem="${path##*/}"; stem="${stem%.tar}"
      [[ -v seen[$stem] ]] || seen["$stem"]=1
    done
  fi
  shopt -u nullglob
  printf '%s\n' "${!seen[@]}" | LC_ALL=C sort
}

list_local() {
  [[ -d $DEST_DIR ]] || { printf 'No local machines. Directory does not exist: %s\n' "$DEST_DIR"; return 0; }
  local -A zip_paths=() extracted=() keys=() completed=()
  local path stem size status count=0 progress_file="$DEST_DIR/.dockerlabs-done"
  shopt -s nullglob
  for path in "$DEST_DIR"/*.zip; do
    [[ -f $path && ! -L $path ]] || continue
    stem="${path##*/}"; stem="${stem%.zip}"
    zip_paths["$stem"]="$path"; keys["$stem"]=1
  done
  for path in "$DEST_DIR"/*/; do
    [[ -d $path && ! -L $path ]] || continue
    stem="${path%/}"; stem="${stem##*/}"
    if [[ -n $(find "$path" -type f -name auto_deploy.sh -print -quit) ]]; then
      extracted["$stem"]="$path"; keys["$stem"]=1
    fi
  done
  if [[ -f $DEST_DIR/auto_deploy.sh && ! -L $DEST_DIR/auto_deploy.sh ]]; then
    for path in "$DEST_DIR"/*.tar; do
      [[ -f $path && ! -L $path ]] || continue
      stem="${path##*/}"; stem="${stem%.tar}"
      if [[ ! -v keys[$stem] ]]; then
        extracted["$stem"]='standalone'
        keys["$stem"]=1
      fi
    done
  fi
  if [[ -f $progress_file && ! -L $progress_file ]]; then
    while IFS= read -r stem || [[ -n $stem ]]; do
      [[ -n $stem ]] || continue
      completed["$stem"]=1
      keys["$stem"]=1
    done < "$progress_file"
  fi
  shopt -u nullglob
  printf '%-30s %-22s %-10s %s\n' 'MACHINE' 'LOCAL STATUS' 'COMPLETED' 'ZIP SIZE'
  printf '%s\n' '--------------------------------------------------------------------------------'
  while IFS= read -r stem; do
    [[ -n $stem ]] || continue
    status='Progress only'
    [[ -v extracted[$stem] ]] && status='Extracted'
    [[ ${extracted[$stem]:-} == standalone ]] && status='Local TAR'
    [[ -v zip_paths[$stem] ]] && status='ZIP downloaded'
    if [[ -v extracted[$stem] && -v zip_paths[$stem] ]]; then status='ZIP + extracted'; fi
    size='—'
    if [[ -v zip_paths[$stem] ]]; then
      size="$(du -h -- "${zip_paths[$stem]}" | awk '{print $1}')"
    fi
    local done_status='No'
    [[ -v completed[$stem] ]] && done_status='YES'
    printf '%-30.30s %-22s %-10s %s\n' "$stem" "$status" "$done_status" "$size"
    count=$((count + 1))
  done < <(printf '%s\n' "${!keys[@]}" | LC_ALL=C sort)
  printf '\nLocal entries: %d\nDirectory: %s\n' "$count" "$DEST_DIR"
}

# Only unpack normal file/directory ZIP members inside a private extraction
# directory. Deny absolute paths, traversal, Windows paths and symlinks.
verify_zip_for_extraction() {
  local zip="$1" member
  command -v unzip >/dev/null 2>&1 || die 'Install unzip to launch machine archives'
  unzip -Z -1 -- "$zip" > "$TEMP_DIR/zip-members" || die 'Cannot read ZIP member list'
  [[ -s $TEMP_DIR/zip-members ]] || die 'ZIP contains no files'
  while IFS= read -r member || [[ -n $member ]]; do
    [[ -n $member && $member != /* && $member != *\\* && $member != *:* &&
       "/$member/" != *'/../'* && "/$member/" != *'/./'* ]] ||
      die "ZIP contains an unsafe entry: $member"
  done < "$TEMP_DIR/zip-members"
  # Symlink entries in Info-ZIP listings have Unix mode starting with l.
  if zipinfo -l -- "$zip" | awk '$1 ~ /^l[rwxstST-]{9}/ { found=1 } END { exit !found }'; then
    die 'ZIP contains symbolic links. Extract and review it manually.'
  fi
}

# Locate the included deployment script and all sibling Docker image TARs.
# Handles both flat and nested ZIP layouts; pivotal labs may contain several TARs.
select_local_bundle() {
  local root="$1" parent
  local -a scripts=() tars=()
  mapfile -d '' scripts < <(find "$root" -type f -name auto_deploy.sh -print0)
  (( ${#scripts[@]} > 0 )) || die "No auto_deploy.sh found under: $root"
  (( ${#scripts[@]} == 1 )) || die "Several deployment scripts found under $root; review manually"
  DEPLOY_SCRIPT="${scripts[0]}"
  parent="$(dirname -- "$DEPLOY_SCRIPT")"
  mapfile -d '' tars < <(find "$parent" -maxdepth 1 -type f -iname '*.tar' -print0 | LC_ALL=C sort -zV)
  (( ${#tars[@]} > 0 )) || die "No .tar image found next to auto_deploy.sh in $parent"
  DEPLOY_DIR="$parent"
  DEPLOY_TARS=("${tars[@]}")
}

# Presence checks are deliberately limited to recognized local archive layouts.
# The archive may still fail integrity/deployment checks when run_local processes it.
has_local_machine() {
  local stem="$1"
  [[ -f "$DEST_DIR/$stem.zip" && ! -L "$DEST_DIR/$stem.zip" ]] ||
  [[ -d "$DEST_DIR/$stem" && ! -L "$DEST_DIR/$stem" ]] ||
  { [[ -f "$DEST_DIR/$stem.tar" && ! -L "$DEST_DIR/$stem.tar" ]] &&
    [[ -f "$DEST_DIR/auto_deploy.sh" && ! -L "$DEST_DIR/auto_deploy.sh" ]]; }
}

run_local() {
  local machine_name="$QUERY" stem zip dir staging='' tarfile response standalone_tar
  local DEPLOY_SCRIPT='' DEPLOY_DIR=''
  local -a DEPLOY_TARS=() cmd=()
  command -v iconv >/dev/null 2>&1 || die 'Missing dependency: iconv'
  command -v sudo >/dev/null 2>&1 || die 'Missing dependency: sudo'
  command -v docker >/dev/null 2>&1 || die 'Install Docker before deploying a lab'
  [[ -d $DEST_DIR ]] || die "Local machine directory does not exist: $DEST_DIR (download a machine first)"
  # Also accept machine.zip as an input, besides a human-readable title.
  machine_name="${machine_name%.zip}"
  machine_name="${machine_name%.tar}"
  stem="$(archive_slug "$machine_name")"
  zip="$DEST_DIR/$stem.zip"
  dir="$DEST_DIR/$stem"
  standalone_tar="$DEST_DIR/$stem.tar"
  if [[ -f $standalone_tar && ! -L $standalone_tar && -f $DEST_DIR/auto_deploy.sh && ! -L $DEST_DIR/auto_deploy.sh && ! -d $dir ]]; then
    DEPLOY_SCRIPT="$DEST_DIR/auto_deploy.sh"
    DEPLOY_DIR="$DEST_DIR"
    DEPLOY_TARS=("$standalone_tar")
  else
    if [[ ! -d $dir ]]; then
      [[ -f $zip && ! -L $zip ]] || die "Machine is not downloaded: $stem (look in $DEST_DIR; try 'dockerlabctl local')"
      verify_zip_for_extraction "$zip"
      staging="$(mktemp -d -- "$DEST_DIR/.${stem}.extract.XXXXXXXX")" || die 'Cannot create a staging directory'
      if ! unzip -q -- "$zip" -d "$staging"; then
        rm -rf -- "$staging"
        die "Failed to extract $zip (possibly password-protected); extract it manually if needed"
      fi
      # Avoid caching incomplete bundles when expected files are missing.
      if ! (select_local_bundle "$staging"); then
        rm -rf -- "$staging"
        die "The archive does not contain a deployable auto_deploy.sh + .tar bundle"
      fi
      if [[ -e $dir ]]; then
        rm -rf -- "$staging"
        die "Refusing to overwrite existing path: $dir"
      fi
      mv -- "$staging" "$dir" || { rm -rf -- "$staging"; die 'Cannot move extracted files'; }
      printf 'Extracted: %s\n' "$dir"
    fi
    select_local_bundle "$dir"
  fi
  printf 'Machine: %s\nDeployment script: %s\n' "$stem" "$DEPLOY_SCRIPT"
  printf 'Images (%d):\n' "${#DEPLOY_TARS[@]}"
  for tarfile in "${DEPLOY_TARS[@]}"; do printf '  %s\n' "${tarfile##*/}"; done
  cmd=(sudo bash "${DEPLOY_SCRIPT##*/}")
  for tarfile in "${DEPLOY_TARS[@]}"; do cmd+=("${tarfile##*/}"); done
  printf 'Command: '
  printf '%q ' "${cmd[@]}"
  printf '\n'
  if (( ${#DEPLOY_TARS[@]} > 1 )); then
    warn 'Multiple image TARs found. Verify the displayed ordering before deployment.'
  fi
  warn 'This runs a third-party shell script with root privileges. Review it first.'
  warn 'Run DockerLabs only in an isolated, authorized lab. Ctrl+C normally stops it.'
  if (( ASSUME_YES == 0 )); then
    [[ -t 0 ]] || die 'Deployment requires an interactive confirmation (or use --yes after reviewing the script)'
    read -r -p 'Deploy this machine? [y/N] ' response || return 1
    [[ ${response,,} == y || ${response,,} == yes ]] || { printf 'Deployment cancelled.\n'; return 1; }
  fi
  # Use a subshell so auto_deploy.sh receives Ctrl+C and keeps its own
  # cleanup handler while the wrapper preserves the caller's working directory.
  ( cd -- "$DEPLOY_DIR" && "${cmd[@]}" )
}

# Website completion is a toggle. Always GET the current state before POSTing.
# A supplied cookie (or private default file) enables website synchronization.
read_private_value() {
  local path="$1" label="$2" data
  [[ -f $path && ! -L $path && -r $path ]] || die "$label must be a readable regular file (not a symlink): $path"
  if [[ -n $(find -- "$path" -maxdepth 0 -perm /077 -print) ]]; then
    die "$label must have mode 600: $path"
  fi
  data="$(cat -- "$path")"
  [[ -n $data && $data != *$'\n'* && $data != *$'\r'* ]] || die "$label must contain one nonempty line"
  printf '%s' "$data"
}
curl_config_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}
profile_init() {
  local cookie csrf status html="$TEMP_DIR/profile-home.html"
  command -v curl >/dev/null || die 'Missing dependency: curl'
  command -v jq >/dev/null || die 'Missing dependency: jq'
  if [[ -z $COOKIE_VALUE && -z $COOKIE_FILE && -f $HOME/.config/dockerlabs/cookie ]]; then
    COOKIE_FILE="$HOME/.config/dockerlabs/cookie"
  fi
  [[ -n $COOKIE_VALUE || -n $COOKIE_FILE ]] || die 'Use --cookie-file FILE or configure ~/.config/dockerlabs/cookie'
  if [[ -n $COOKIE_FILE ]]; then cookie="$(read_private_value "$COOKIE_FILE" 'Cookie file')"; else cookie="$COOKIE_VALUE"; fi
  cookie="${cookie#Cookie: }"
  [[ $cookie == *'='* && $cookie != *$'\n'* && $cookie != *$'\r'* ]] || die 'Invalid Cookie value'
  PROFILE_CONFIG="$TEMP_DIR/profile-curl.conf"
  (umask 077; printf 'cookie = '; curl_config_quote "$cookie"; printf '\n') > "$PROFILE_CONFIG"
  if [[ -n $CSRF_FILE ]]; then csrf="$(read_private_value "$CSRF_FILE" 'CSRF file')"; else csrf="$CSRF_VALUE"; fi
  if [[ -z $csrf ]]; then
    # Retrieve CSRF in the SAME authenticated session; do not guess values.
    if ! status="$(curl --silent --show-error --config "$PROFILE_CONFIG" --proto '=https' --proto-redir '=https' \
      --connect-timeout 12 --max-time 45 --url 'https://dockerlabs.es/' \
      --output "$html" --write-out '%{http_code}')"; then
      die 'Cannot retrieve the authenticated DockerLabs page to find CSRF'
    fi
    [[ $status == 200 ]] || die "DockerLabs homepage returned HTTP $status"
    csrf="$(perl -0777 -ne '
      use HTML::Entities qw(decode_entities);
      my $html = $_;
      for my $tag ($html =~ /<(?:meta|input)\b[^>]*>/ig) {
        my %a;
        while ($tag =~ /([\w-]+)\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27)/g) { $a{lc $1}=decode_entities(defined $2 ? $2 : $3) }
        if ((($a{name}//"") =~ /^(?:csrf-token|csrf_token|csrfmiddlewaretoken)$/i || ($a{id}//"") =~ /^(?:csrf-token|csrf_token)$/i)) {
          my $v=$a{content}//$a{value}//""; if ($v ne "") { print $v; exit }
        }
      }
      for my $pattern (qr/\bcsrf(?:_?token)?\s*[:=]\s*["\x27]([a-zA-Z0-9._-]{16,})["\x27]/i,
                       qr/["\x27]X-CSRFToken["\x27]\s*:\s*["\x27]([a-zA-Z0-9._-]{16,})["\x27]/i) {
        if ($html =~ $pattern) { print $1; exit }
      }
    ' "$html")"
    [[ -n $csrf ]] || die 'CSRF not found in authenticated page; use --csrf-file as fallback (site markup may have changed)'
  fi
  [[ $csrf =~ ^[a-zA-Z0-9._-]+$ ]] || die 'Invalid CSRF value'
  (umask 077; printf 'header = '; curl_config_quote "X-CSRFToken: $csrf"; printf '\n') >> "$PROFILE_CONFIG"
}
profile_get() {
  local name="$1" status response="$TEMP_DIR/profile-get.json" encoded
  # jq URL encodes path components; prevent slashes in machine titles from becoming path segments.
  encoded="$(jq -nr --arg x "$name" '$x|@uri')"
  if ! status="$(curl --silent --show-error --config "$PROFILE_CONFIG" --proto '=https' --proto-redir '=https' \
    --connect-timeout 12 --max-time 45 --header 'Accept: application/json' \
    --url "https://dockerlabs.es/api/completed_machines/$encoded" \
    --output "$response" --write-out '%{http_code}')"; then
    die "Could not query remote state for '$name'"
  fi
  [[ $status == 200 ]] || die "Remote status for '$name' returned HTTP $status; local progress unchanged"
  jq -e '.completed | type == "boolean"' "$response" >/dev/null 2>&1 || die "Invalid remote status for '$name'"
  jq -r '.completed' "$response"
}
profile_set() {
  local name="$1" desired="$2" current status result response="$TEMP_DIR/profile-post.json" payload="$TEMP_DIR/profile-post-body.json"
  current="$(profile_get "$name")"
  if [[ $current == "$desired" ]]; then
    printf 'Website: %s already %s\n' "$name" "$desired"
    return 0
  fi
  jq -n --arg machine_name "$name" '{machine_name:$machine_name}' > "$payload"
  if ! status="$(curl --silent --show-error --config "$PROFILE_CONFIG" --proto '=https' --proto-redir '=https' \
    --connect-timeout 12 --max-time 45 --request POST \
    --url 'https://dockerlabs.es/api/toggle_completed_machine' \
    --header 'Accept: application/json' --header 'Content-Type: application/json' \
    --data-binary "@$payload" --output "$response" --write-out '%{http_code}')"; then
    die "Could not update '$name'; remote result uncertain, local progress unchanged"
  fi
  [[ $status == 200 ]] || die "Update for '$name' returned HTTP $status; remote result uncertain"
  jq -e '.success == true and (.completed | type == "boolean")' "$response" >/dev/null 2>&1 || die "Invalid update response for '$name'"
  result="$(jq -r '.completed' "$response")"
  [[ $result == "$desired" ]] || die "Unexpected remote state after toggle for '$name'; local progress unchanged"
  # Verify result after write; do not trust response alone.
  result="$(profile_get "$name")"
  [[ $result == "$desired" ]] || die "Remote verification failed for '$name'; local progress unchanged"
  printf 'Website: %s -> %s\n' "$name" "$desired"
}
progress_local_set() {
  local stem="$1" desired="$2" progress_file="$DEST_DIR/.dockerlabs-done"
  if [[ $desired == true ]]; then
    { cat "$progress_file"; printf '%s\n' "$stem"; } | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u > "$TEMP_DIR/progress.new"
  else
    grep -Fvx -- "$stem" "$progress_file" > "$TEMP_DIR/progress.new" || true
  fi
  mv -- "$TEMP_DIR/progress.new" "$progress_file"
}
resolve_progress_machine() {
  local q="$1" records count
  records="$(jq -c --arg q "$q" "$JQ_NORM [ .machines[] | select((.name | norm) == (\$q | norm) or ((.id | tostring) == \$q)) ]" "$CACHE_FILE")"
  count="$(jq 'length' <<< "$records")"
  if (( count == 0 )); then
    records="$(jq -c --arg q "$q" "$JQ_NORM [ .machines[] | select(.name | norm | contains(\$q | norm)) ]" "$CACHE_FILE")"
    count="$(jq 'length' <<< "$records")"
  fi
  (( count == 1 )) || die "Machine '$q' not found or ambiguous ($count matches)"
  jq -r '.[0].name' <<< "$records"
}

# Resolve numeric catalog IDs for offline file-management commands.
# Names and archive stems remain fully offline; numeric IDs require catalog data.
resolve_local_id() {
  [[ $QUERY =~ ^[0-9]+$ ]] || return 0
  command -v jq >/dev/null 2>&1 || die 'Missing dependency: jq (required to resolve numeric machine IDs)'
  if [[ ! -s $CACHE_FILE ]] || ! jq -e '.machines | type == "array" and length > 0' "$CACHE_FILE" >/dev/null 2>&1; then
    require_online_dependencies
    load_catalog
  fi
  local name count
  count="$(jq --arg q "$QUERY" '[.machines[] | select((.id | tostring) == ($q | tonumber | tostring))] | length' "$CACHE_FILE")"
  [[ $count == 1 ]] || die "Machine ID $QUERY not found or ambiguous in catalog"
  name="$(jq -r --arg q "$QUERY" '.machines[] | select((.id | tostring) == ($q | tonumber | tostring)) | .name' "$CACHE_FILE")"
  [[ -n $name ]] || die "Machine ID $QUERY has no name in catalog"
  QUERY="$name"
}

if [[ $COMMAND == local ]]; then
  list_local
  exit 0
fi
if [[ $COMMAND == deploy ]]; then
  resolve_local_id
  # Deploy is intentionally offline and fails if the requested machine is absent.
  run_local
  exit 0
fi
if [[ $COMMAND == remove ]]; then
  resolve_local_id
  # Remove only this machine's local files; do not touch Docker containers/images.
  command -v iconv >/dev/null 2>&1 || die 'Missing dependency: iconv'
  machine_name="${QUERY%.zip}"
  machine_name="${machine_name%.tar}"
  stem="$(archive_slug "$machine_name")"
  zip_path="$DEST_DIR/$stem.zip"
  dir_path="$DEST_DIR/$stem"
  standalone_tar="$DEST_DIR/$stem.tar"
  found=0
  [[ -f $zip_path && ! -L $zip_path ]] && found=1
  [[ -d $dir_path && ! -L $dir_path ]] && found=1
  if [[ -f $standalone_tar && ! -L $standalone_tar && -f $DEST_DIR/auto_deploy.sh && ! -L $DEST_DIR/auto_deploy.sh ]]; then
    found=1
  fi
  (( found )) || die "No local files found for '$stem' in $DEST_DIR (see: dockerlabctl local)"
  printf 'Local files to remove for %s:\n' "$stem"
  [[ -f $zip_path && ! -L $zip_path ]] && printf '  ZIP: %s\n' "$zip_path"
  [[ -d $dir_path && ! -L $dir_path ]] && printf '  Directory: %s\n' "$dir_path"
  if [[ -f $standalone_tar && ! -L $standalone_tar && -f $DEST_DIR/auto_deploy.sh && ! -L $DEST_DIR/auto_deploy.sh ]]; then
    printf '  Standalone TAR: %s\n' "$standalone_tar"
  fi
  warn 'This removes local files only. It does not stop or remove Docker containers, images, or networks.'
  if (( ASSUME_YES == 0 )); then
    [[ -t 0 ]] || die 'Removal requires interactive confirmation (or use --yes)'
    read -r -p 'Permanently remove these local files? [y/N] ' response || exit 1
    [[ ${response,,} == y || ${response,,} == yes ]] || { printf 'Removal cancelled.\n'; exit 1; }
  fi
  [[ ! -f $zip_path || -L $zip_path ]] || rm -f -- "$zip_path"
  [[ ! -d $dir_path || -L $dir_path ]] || rm -rf -- "$dir_path"
  if [[ -f $standalone_tar && ! -L $standalone_tar && -f $DEST_DIR/auto_deploy.sh && ! -L $DEST_DIR/auto_deploy.sh ]]; then
    rm -f -- "$standalone_tar"
  fi
  printf 'Removed local files for %s.\n' "$stem"
  exit 0
fi
if [[ $COMMAND == progress ]]; then
  command -v iconv >/dev/null || die 'Missing dependency: iconv'
  mkdir -p -- "$DEST_DIR" || die 'Cannot create progress directory'
  require_online_dependencies
  load_catalog
  progress_file="$DEST_DIR/.dockerlabs-done"
  [[ ! -L $progress_file ]] || die 'Progress file must not be a symlink'
  (umask 077; touch -- "$progress_file")
  if [[ $PROGRESS_ACTION == list ]]; then
    mode="${PROGRESS_NAMES[0]:-local}"
    if [[ $mode == remote || $mode == both ]]; then
      profile_init
    fi
    if [[ $mode == both ]]; then
      printf '%-6s %-30s %-9s %-9s %s\n' 'ID' 'MACHINE' 'LOCAL' 'PROFILE' 'STATUS'
      printf '%s\n' '-----------------------------------------------------------------------'
    else
      printf 'Completed machines (%s):\n' "$([[ $mode == remote ]] && echo profile || echo local)"
    fi
    count=0
    local_count=0
    remote_count=0
    differences=0
    while IFS=$'\t' read -r id name; do
      stem="$(archive_slug "$name")"
      local_done=false
      grep -Fqx -- "$stem" "$progress_file" && local_done=true
      remote_done=false
      if [[ $mode != local ]]; then remote_done="$(profile_get "$name")"; fi
      [[ $local_done == true ]] && local_count=$((local_count + 1))
      [[ $remote_done == true ]] && remote_count=$((remote_count + 1))
      if [[ $mode == both ]]; then
        status='OK'
        if [[ $local_done != "$remote_done" ]]; then
          status='DIFFERENT'
          differences=$((differences + 1))
        fi
        # Only show completed or mismatched entries to avoid flooding the terminal.
        if [[ $local_done == true || $remote_done == true ]]; then
          printf '%-6s %-30.30s %-9s %-9s %s\n' "$id" "$name" "$local_done" "$remote_done" "$status"
          count=$((count + 1))
        fi
      elif [[ $mode == remote && $remote_done == true ]] || [[ $mode == local && $local_done == true ]]; then
        printf '  %-30s (ID: %s)\n' "$name" "$id"
        count=$((count + 1))
      fi
      if [[ $mode != local ]]; then sleep 0.25; fi
    done < <(jq -r '.machines[] | [.id,.name] | @tsv' "$CACHE_FILE")
    if [[ $mode == both ]]; then
      printf 'Local completed: %d | Profile completed: %d | Differences: %d\n' "$local_count" "$remote_count" "$differences"
    else
      printf 'Total: %d\n' "$count"
    fi
    exit 0
  fi
  # Reads of local progress are the default. Only -p, fetch and push touch the profile.
  AUTHENTICATED=0
  if (( PROGRESS_PUSH )) || [[ $PROGRESS_ACTION == fetch || $PROGRESS_ACTION == push ]]; then
    profile_init
    AUTHENTICATED=1
  fi
  names=()
  if [[ ${PROGRESS_NAMES[0]} == all ]]; then
    if [[ $PROGRESS_ACTION == fetch || $PROGRESS_ACTION == push ]]; then
      warn "Full $PROGRESS_ACTION checks every catalog machine against your profile."
      if (( ASSUME_YES == 0 )); then
        [[ -t 0 ]] || die "Use --yes to confirm full profile $PROGRESS_ACTION"
        read -r -p "Check all catalog machines? [y/N] " reply || exit 1
        [[ ${reply,,} == y || ${reply,,} == yes ]] || exit 1
      fi
      mapfile -t names < <(jq -r '.machines[].name' "$CACHE_FILE")
    else
      # 'done all' and 'undone all' target only local downloads.
      mapfile -t stems < <(local_machine_stems)
      # Validate the complete list before a remote write: avoid partial updates
      # when a local filename has no matching catalog entry.
      if (( PROGRESS_PUSH )); then
        for stem in "${stems[@]}"; do
          name="$(jq -r --arg stem "$stem" '.machines[] | select((.name|ascii_downcase|gsub(" ";""))==$stem) | .name' "$CACHE_FILE" | head -1)"
          [[ -n $name ]] || die "Unknown local archive '$stem'; cannot safely apply -p (no changes made)"
        done
      fi
      for stem in "${stems[@]}"; do
        name="$(jq -r --arg stem "$stem" '.machines[] | select((.name|ascii_downcase|gsub(" ";""))==$stem) | .name' "$CACHE_FILE" | head -1)"
        if [[ -n $name ]]; then
          names+=("$name")
        elif (( PROGRESS_PUSH )); then
          # Do not silently claim a two-sided success for an unknown machine.
          die "Unknown local archive '$stem'; cannot safely apply -p (no changes made for this entry)"
        else
          progress_local_set "$stem" "$([[ $PROGRESS_ACTION == done ]] && echo true || echo false)"
        fi
      done
    fi
  else
    for q in "${PROGRESS_NAMES[@]}"; do names+=("$(resolve_progress_machine "$q")"); done
  fi
  for name in "${names[@]}"; do
    stem="$(archive_slug "$name")"
    case "$PROGRESS_ACTION" in
      fetch)
        remote_done="$(profile_get "$name")"
        progress_local_set "$stem" "$remote_done"
        printf 'Fetched: %s -> local completed %s (website authoritative)\n' "$name" "$remote_done"
        ;;
      push)
        desired=false
        if grep -Fqx -- "$stem" "$progress_file"; then desired=true; fi
        profile_set "$name" "$desired"
        printf 'Pushed: %s -> website completed %s (local authoritative)\n' "$name" "$desired"
        ;;
      done|undone)
        desired=false
        [[ $PROGRESS_ACTION == done ]] && desired=true
        # -p is explicit; if remote write fails, leave this machine's local record unchanged.
        if (( PROGRESS_PUSH )); then profile_set "$name" "$desired"; fi
        progress_local_set "$stem" "$desired"
        if (( PROGRESS_PUSH )); then
          printf 'Progress: %s -> %s (local + website)\n' "$name" "$desired"
        else
          printf 'Progress: %s -> %s (local only)\n' "$name" "$desired"
        fi
        ;;
    esac
    if [[ ${PROGRESS_NAMES[0]} == all && ( $PROGRESS_ACTION == fetch || $PROGRESS_ACTION == push ) ]]; then sleep 0.25; fi
  done
  exit 0
fi

if [[ $COMMAND == run ]]; then
  # Fast offline path: prefer local ZIP, extracted folder or standalone TAR.
  # If none exists, resolve a catalog name/ID and download its ZIP first.
  local_name="${QUERY%.zip}"
  local_name="${local_name%.tar}"
  local_stem="$(archive_slug "$local_name")"
  if has_local_machine "$local_stem"; then
    printf 'Using local machine: %s\n' "$local_stem"
  else
    printf 'Machine not found locally. Checking DockerLabs catalog...\n'
    require_online_dependencies
    load_catalog
    machine="$(select_machine)"
    QUERY="$(jq -r '.name' <<< "$machine")"
    resolved_stem="$(archive_slug "$QUERY")"
    if has_local_machine "$resolved_stem"; then
      printf 'Using local machine: %s\n' "$resolved_stem"
    else
      run_download "$machine" || exit $?
    fi
  fi
  run_local
  exit 0
fi

load_catalog
case "$COMMAND" in
  list|name|search)
    records="$(filter_catalog)"
    records="$(filter_completed "$records")"
    if (( AS_JSON )); then
      if (( LIMIT > 0 )); then jq --argjson n "$LIMIT" '.[:$n]' <<< "$records"; else jq '.' <<< "$records"; fi
    else
      print_table "$records"
    fi
    [[ "$(jq 'length' <<< "$records")" -gt 0 ]] || exit 1
    ;;
  random)
    records="$(filter_catalog)"
    records="$(filter_completed "$records")"
    count="$(jq 'length' <<< "$records")"
    (( count > 0 )) || die 'No matching machines'
    index="$(shuf -i "0-$((count-1))" -n 1)"
    records="$(jq -c --argjson n "$index" '[ .[$n] ]' <<< "$records")"
    if (( AS_JSON )); then jq '.' <<< "$records"; else print_table "$records"; fi
    ;;
  info|link|download)
    machine="$(select_machine)"
    if [[ $COMMAND == info ]]; then
      jq -r '"Name:       \(.name)\nID:         \(.id)\nDifficulty: \(.difficulty)\nCategory:   \(.category)\nAuthor:     \(.author)\nDate:       \(.date)\nDescription: \(.description // "No description available")"' <<< "$machine"
      printf 'Archive:    %s\n' "$(archive_url "$(archive_slug "$(jq -r '.name' <<< "$machine")")")"
    else
      run_download "$machine"
    fi
    ;;
esac
