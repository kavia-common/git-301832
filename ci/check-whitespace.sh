#!/usr/bin/env bash
#
# Check that commits after a specified point do not contain new or modified
# lines with whitespace errors. An optional formatted summary can be generated
# by providing an output file path and url as additional arguments.
#

# Harden execution:
# -e: fail fast on errors; -u: catch unset vars; -o pipefail: propagate failures in pipelines.
# We keep bash because the original script uses arrays and bash-specific parameter expansion.
set -euo pipefail

baseCommit=${1-}
outputFile=${2-}
url=${3-}

if { test "$#" -ne 1 && test "$#" -ne 3; } || test -z "${baseCommit}"
then
	echo "USAGE: $0 <BASE_COMMIT> [<OUTPUT_FILE> <URL>]"
	exit 1
fi

# Ensure base commit is valid before doing any work.
if ! git rev-parse --quiet --verify "${baseCommit}" >/dev/null
then
	echo "Invalid <BASE_COMMIT> '${baseCommit}'"
	exit 1
fi

# Accumulate formatted output for optional summary.
problems=()

commit=
commitText=
commitTextmd=
goodParent=

# Stream git output directly instead of capturing it all with $(...) to handle large repos better.
# Use --pretty=format with a delimiter line that starts with '---' (same as before).
while IFS= read -r line
do
	# Fast path: ignore blank lines.
	test -n "$line" || continue

	case "$line" in
	---\ *) # Line contains commit information.
		# Extract "sha subject" from the header line "---@<sha> <subject>"
		# We keep behaviour consistent with original output.
		sha=${line#--- }
		sha=${sha%% *}
		etc=${line#--- "$sha"}

		if test -z "${goodParent}"
		then
			# Assume the commit has no whitespace errors until detected otherwise.
			goodParent=${sha}
		fi

		commit=${sha}
		commitText="${sha}${etc}"
		commitTextmd="[${sha}](${url}/commit/${sha})${etc}"
		;;
	*) # Whitespace error information line for current commit.
		# Print commit header only once per offending commit, just like the original.
		if test -n "${goodParent}"
		then
			problems+=("1) --- ${commitTextmd}")
			echo ""
			echo "--- ${commitText}"
			goodParent=
		fi

		# Split the line into fields like original "read dash sha etc" did.
		# The first token is either:
		#   - "path:line:" (linkable)
		#   - some other token (rendered as inline code)
		dash=${line%% *}
		rest=${line#"$dash"}
		rest=${rest# } # trim one leading space if present

		sha=
		etc=
		if test -n "$rest" && test "$rest" != "$line"
		then
			sha=${rest%% *}
			if test "$sha" = "$rest"
			then
				etc=
			else
				etc=${rest#"$sha"}
				etc=${etc# }
			fi
		fi

		case "${dash}" in
		*:[1-9]*:) # contains file and line number information
			# dashend is the substring after first ':', used to compute line number.
			dashend=${dash#*:}
			problems+=("[${dash}](${url}/blob/${commit}/${dash%%:*}#L${dashend%:}) ${sha} ${etc}")
			;;
		*)
			problems+=("\`${dash} ${sha} ${etc}\`")
			;;
		esac

		echo "${dash} ${sha} ${etc}"
		;;
	esac
done < <(git log --check --pretty=format:"--- %h %s" "${baseCommit}"..)

if test ${#problems[@]} -gt 0
then
	# Preserve original behaviour: if we ended inside an offending commit, fall back to
	# the abbreviated base commit as the parent to rebase onto.
	if test -z "${goodParent}"
	then
		# Original used substring expansion: ${baseCommit: 0:7}
		# Keep it for behaviour consistency with long SHA inputs.
		goodParent=${baseCommit:0:7}
	fi

	echo "A whitespace issue was found in one or more of the commits."
	echo "Run the following command to resolve whitespace issues:"
	echo "git rebase --whitespace=fix ${goodParent}"

	# If target output file is provided, write formatted output.
	if test -n "${outputFile}"
	then
		echo "🛑 Please review the Summary output for further information."
		(
			echo "### :x: A whitespace issue was found in one or more of the commits."
			echo ""
			echo "Run these commands to correct the problem:"
			echo "1. \`git rebase --whitespace=fix ${goodParent}\`"
			echo "1. \`git push --force\`"
			echo ""
			echo "Errors:"

			for i in "${problems[@]}"
			do
				echo "${i}"
			done
		) >"${outputFile}"
	fi

	exit 2
fi
