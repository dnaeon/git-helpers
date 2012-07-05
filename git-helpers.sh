# Copyright (c) 2012  Marin Atanasov Nikolov  <dnaeon@gmail.com>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

# List of available commands
COMMANDS="\
	apply	Applies a patch to the specified branch
	init	Perform initial setup of the helpers
	new	Starts off a new change
	pull	Performs a pull on the Cfengine servers
	revert	Reverts a change from the specified branch
	squash	Creates a patch from a squashed merge against a specified branch
	sync	Syncs a branch using rebase
	verify	Verifies a patch against the specified branch"

# Display an INFO message
# $1: Message to display
_msg_info() {
    local _msg="${1}"

    echo ">>> INFO  : ${_msg}"
}

# Display an ERROR message
# $1: Message to display
# $2: Exit code
_msg_error() {
    local _msg="${1}"
    local _rc=${2}
    
    echo ">>> ERROR : ${_msg}"

    if [ ${_rc} -ne 0 ]; then
        exit ${_rc}
    fi
}

# Provide a yes/no prompt to the user
# Default answer is YES
# $1: Prompt message
# $2: Default answer
# return: 0 if user selected YES, 1 if NO
_yesno_prompt() {
    local _msg="${1}"
    local _default=${2}
    local _answer
    local _second_prompt

    if [ ${_default} -eq 0 ]; then
	_second_prompt="[Y/n]:"
    elif [ ${_default} -eq 1 ]; then
	_second_prompt="[y/N]:"
    fi

    read -p ">>> INPUT : ${_msg} ${_second_prompt} " _answer

    # user pressed ENTER, return default answer
    if [[ -z "${_answer}" ]]; then
	return ${_default}
    fi

    if [[ ${_answer^^} == "Y" ]]; then
	return 0
    elif [[ ${_answer^^} == "N" ]]; then
	return 1
    else
	# not a valid response
	_yesno_prompt "${_msg}" ${_default}
    fi
}

# Perform sanity checks
_sanity_check() {

    if [[ -z "$( whereis git | cut -d ':' -f 2 )" ]]; then
	_msg_error "Cannot find git executable in your PATH" 0
	_msg_error "Please check if Git is already installed" 64 # EX_USAGE
    fi

    if [[ -z "$( whereis ssh-copy-id | cut -d ':' -f 2 )" ]]; then
	_msg_error "Cannot find ssh-copy-id executable in your PATH" 0
	_msg_error "Please check if ssh-copy-id is already installed" 64 # EX_USAGE
    fi

    if [[ -z "${PAGER}" ]]; then
	_msg_error "It appears you do not have a PAGER set" 0
	_msg_error "Please set your preffered PAGER in your profile first" 64 # EX_USAGE
    fi
}

# Check if working tree is clean
# return: 0 if it is clean, 1 otherwise
_git_working_tree_is_clean() {
    
    if [[ ! -z "$( git status --porcelain )" ]]; then
	return 1
    else
	return 0
    fi
}

# Verify that a given branch exists in Git
# $1: Branch name
# return: 0 if branch exists, > 0 otherwise
_git_branch_exists() {
    local _branch="${1}"
    
    git show-ref --verify --quiet refs/heads/${_branch}

    return $?
}

# Verify that a given tag exists in Git
# $1: Tag name
# return: 0 if the tag exists, > 0 otherwise
_git_tag_exists() {
    local _tag="${1}"
    
    git show-ref --verify --quiet refs/tags/${_tag}
    
    return $?
}

# Checks out a branch
# $1: Branch to checkout
_git_checkout_branch() {
    local _branch="${1}"
    
    if ! _git_working_tree_is_clean; then
	_msg_error "Your working tree is not clean" 0 
	_msg_error "Cannot checkout a branch if your working tree is dirty" 0
	_msg_error "Check 'git status' for more information" 64 # EX_USAGE
    fi

    if ! _git_branch_exists ${_branch}; then
	_msg_error "The specified branch '${_branch}' does not exists" 64 # EX_USAGE
    fi

    git checkout -q ${_branch}
}

# Create a temporary branch
# $1: A branch to start off
_git_create_temp_branch() {
    local _branch="${1}"

    if ! _git_branch_exists ${_branch}; then
	_msg_error "The specified branch '${_branch}' does not exists" 64 # EX_USAGE
    fi

    _msg_info "Creating a temporary branch"
    git branch -f tmp ${_branch}
}

# Updates a branch
# $1: Branch to update
# return: 0 if pull was successful, > 0 otherwise
_git_update_branch() {
    local _branch="${1}"
    local _prev_branch=$( git rev-parse --abbrev-ref HEAD )
    local _rc
    
    _git_checkout_branch ${_branch}
    
    _msg_info "Updating branch '${_branch}'"
    git pull -q --rebase > /dev/null 2>&1
    _rc=$?

    _git_checkout_branch ${_prev_branch}
    
    return ${_rc}
}

# Pushes to the remote repository
# $1: Branch name
# return: 0 if push was successul, > 0 otherwise
_git_push_branch() {
    local _branch="${1}"
    local _cmd_out
    local _rc

    _msg_info "Pushing to the remote repository"
    _cmd_out=$( git push --tags origin ${_branch} 2>&1 ) 
    _rc=$?

    if [[ ${_rc} -ne 0 ]]; then
	_msg_error "Failed to push to the remote repository" 0
	
	if _yesno_prompt "Display the output of the push command?" 0 ; then
	    ${PAGER} <<<"${_cmd_out}"
	fi
    fi

    return ${_rc}
}

# Verify if a merge can be performed
# $1: Branch to merge
# $2: Squash merge (0 means --no-squash, 1 means --squash)
# return: 0 if merge can be performed, 1 otherwise
_git_verify_merge() {
    local _merge_branch="${1}"
    local _squash=${2}
    local _prev_branch=$( git rev-parse --abbrev-ref HEAD )
    local _merge_opts
    local _rc

    if ! _git_branch_exists ${_merge_branch} ; then
	_msg_error "The specified branch for merging '${_merge_branch}' does not exists" 0
	return 1
    fi

    case ${_squash} in
	0) _merge_opts="" ;;		# no options to the merge command
	1) _merge_opts="--squash" ;; 	# perform a squash merge
    esac

    _git_update_branch ${_merge_branch}
    _git_create_temp_branch ${_merge_branch}
    _git_checkout_branch "tmp"

    _msg_info "Verifying if merge is possible"
    _cmd_out=$( git merge "${_merge_opts}" ${_prev_branch} 2>&1 )
    _rc=$?

    # reset the merge, as this is only verification
    git reset -q --merge

    if [ ${_rc} -ne 0 ]; then
	_msg_error "Failed to perform the merge" 0 

	_msg_error "Cleaning up the working tree" 0
	git reset -q --merge

	if _yesno_prompt "Display the output of the merge?" 0 ; then
	    ${PAGER} <<<"${_cmd_out}"
	fi
    else
	_msg_info "Merge verified successfully"
    fi

    _git_checkout_branch ${_prev_branch}

    return ${_rc}
}

# Verify if revert can be made
# $1: Branch name
# $2: Tag name
# return: 0 if revert is possible, > 0 otherwise
_git_verify_revert() {
    local _branch="${1}"
    local _tag="${2}"
    local _sha1_id=$( git rev-parse --short ${_tag} )
    local _prev_branch=$( git rev-parse --abbrev-ref HEAD )
    local _rc
    local _cmd_out

    _git_update_branch ${_branch}
    _git_create_temp_branch ${_branch}
    _git_checkout_branch "tmp"

    _msg_info "Verifying if reverting '${_tag}' [SHA1: ${_sha1_id}] is possible"

    _cmd_out=$( git revert -n ${_sha1_id} 2>&1 )
    _rc=$?

    # abort the revert, as this is just verification
    git revert --abort > /dev/null 2>&1
    
    if [ ${_rc} -ne 0 ]; then
	_msg_error "Failed to revert '${_tag}' [SHA1: ${_sha1_id}]"
	
	if _yesno_prompt "Display the output of the revert command?" 0 ; then
	    ${PAGER} <<<"${_cmd_out}"
	fi
    else
	_msg_info "Revert verification successful"
    fi

    _git_checkout_branch ${_prev_branch}

    return ${_rc}
}

# Verify if a rebase operation is possible
# $1: Branch which we rebase against
# return: 0 if rebase is possible, > 0 otherwise
_git_verify_rebase() {
    local _rebase_branch="${1}"
    local _prev_branch=$( git rev-parse --abbrev-ref HEAD )
    local _rc

    if ! _git_branch_exists ${_rebase_branch} ; then
	_msg_error "The specified branch '${_rebase_branch}' does not exists" 0
	return 1
    fi

    _git_update_branch ${_rebase_branch}
    _git_create_temp_branch ${_prev_branch}
    _git_checkout_branch "tmp"

    _msg_info "Verifying if syncing '${_prev_branch}' with '${_rebase_branch}' is possible"
    
    git rebase -q --verify ${_rebase_branch} > /dev/null 2>&1
    _rc=$?

    if [ ${_rc} -ne 0 ]; then
	_msg_error "Sync verification failed" 0
	_msg_error "You are advised to manually sync '${_prev_branch}' with '${_rebase_branch}'" 0 
	_msg_error " and then fix all possible conflicts during the sync process" 0 
	_msg_error "To start a manual sync execute 'git checkout ${_prev_branch} && git rebase ${_rebase_branch}'" 0 
	git rebase --abort
    else
	_msg_info "Sync verification successful"
    fi

    _git_checkout_branch ${_prev_branch}

    return ${_rc}
}

# Usage information for the 'git change' command
# return: EX_USAGE
_usage() {

    echo "usage: git change <command> [options] [args]"
    echo ""
    echo "The following commands are available:"
    echo "${COMMANDS}"
    echo ""
    echo "For more information on a command see 'git change help <command>'"
    
    exit 64 # EX_USAGE
}

# Display usage information for the available commands
# $1: Command which we want to display info about
_exec_help() {
    local _help_cmd="${1}"
    local _found_cmd=0
    local _cmd

    for _cmd in ${COMMANDS}; do
	if [[ "${_cmd}" == "${_help_cmd}" ]]; then
	    _found_cmd=1
	    break
	fi
    done

    # display usage function if command was found or error otherwise
    if [ ${_found_cmd} -eq 1 ]; then
        usage_"${_help_cmd}"
    else
        _msg_error "Invalid command name specified" 0
        _msg_error "No such command '${_help_cmd}' found" 64 # EX_USAGE
    fi
    
    exit 0 # EX_OK
}

# Display usage information for 'git change verify'
# return: EX_USAGE
usage_verify() {
    
    echo "usage: git change verify -b <branch> -f <patch-file>"
    echo ""
    echo "Verifies a patch against the specified branch"
    echo ""
    echo "This command only verifies if patch applies cleanly"
    echo "on a specific branch, without actually applying the patch"
    echo ""
    echo "Example usage: git change verify -b STABLE -f RFC-WXYZ.patch"
    
    exit 64 # EX_USAGE
}

# Verify a patch against a specified branch
# $1: Branch name [ -b <branch> ]
# $2: Patch file [ -f <patch> ]
exec_verify() {
    local _rc
    local _branch
    local _patch
    local _cmd_out
    local _prev_branch=$( git rev-parse --abbrev-ref HEAD )

    # reset getopts
    OPTIND=1

    # Parse command-line options
    while getopts 'b:f:' arg; do
	case "${arg}" in
            b) _branch="${OPTARG}" ;;
            f) _patch="${OPTARG}" ;;
            ?) usage_verify ;;
	esac
    done

    shift $((OPTIND - 1))

    if [[ $# -ne 0 ]]; then
	usage_verify
    fi

    if [[ ( -z "${_branch}" ) || ( -z "${_patch}" ) ]]; then
	usage_verify
    fi

    if [[ ! -f ${_patch} ]]; then
	_msg_error "The specified patch file '${_patch}' does not exists" 65 # EX_DATAERR
    fi

    _msg_info "Verifying patch against branch '${_branch}'"

    _git_update_branch ${_branch}
    _git_checkout_branch ${_branch}

    _cmd_out=$( git apply --check ${_patch} 2>&1 )
    _rc=$?

    if [[ ${_rc} -ne 0 ]]; then
	_msg_error "Ooops... patch does not apply cleanly..." 0
	_msg_error "Please apply the patch manually and resolve any conflicts" 0
	
	if _yesno_prompt "Display the output of applying the patch?" 0 ; then
	    ${PAGER} <<<"${_cmd_out}"
	fi
    else
	_msg_info "Patch applies cleanly! You are good to go!"
    fi

    # checkout the branch we were before testing the patch
    _git_checkout_branch ${_prev_branch}

    return ${_rc}
}

# Display usage information for 'git change apply'
# return: EX_USAGE
usage_apply() {
    
    echo "usage: git change apply -b <branch> -t <tag> -f <patch-file>"
    echo ""
    echo "Applies a patch to the specified branch"
    echo ""
    echo "This command will apply a patch to the specified branch,"
    echo "tag the newly created commit as <tag> and push the changes"
    echo "to the remote Git repository at <branch>"
    echo ""
    echo "Example usage: git change apply -b STABLE -t RFC-WXYZ-STABLE -f RFC-WXYZ.patch"
    
    exit 64 # EX_USAGE
}

# Apply patch to a specified branch
# $1: Branch name [ -b <branch> ]
# $2: Tag name [ -t <tag> ]
# $3: Patch file [ -f <patch> ]
exec_apply() {
    local _branch
    local _tag
    local _patch
    local _sha1_id
    local _cmd_out
    local _prev_branch=$( git rev-parse --abbrev-ref HEAD )

    # reset getopts
    OPTIND=1

    # Parse command-line options
    while getopts 'b:t:f:' arg; do
	case "${arg}" in
            b) _branch="${OPTARG}" ;;
	    t) _tag="${OPTARG}" ;;
            f) _patch="${OPTARG}" ;;
            ?) usage_apply ;;
	esac
    done

    shift $((OPTIND - 1))

    if [[ $# -ne 0 ]]; then
	usage_apply
    fi

    # check if we have any arguments at all
    if [[ ( -z "${_branch}" ) || ( -z "${_tag}" ) || ( -z "${_patch}" ) ]]; then
	usage_apply
    fi

    # Check if the specified tag name exists already
    if _git_tag_exists ${_tag} ; then
	_msg_error "The specified tag '${_tag}' already exists" 0
	_msg_error "Please use a different tag name or remove the already existsing one" 0

	if _yesno_prompt "Revert '${_tag}' and apply the current patch?" 1 ; then
	    _msg_info "Reverting '${_tag}' as requested"
	    exec_revert -b ${_branch} -t ${_tag} -p 0
	    _msg_info "Now will apply '${_patch}' after back from reverting '${_tag}'"
	else
	    _msg_error "Aborting patch applying due to existing tag" 65 # EX_DATAERR
	fi
    fi
    
    # Verify the patch before applying
    if ! exec_verify -b "${_branch}" -f "${_patch}"; then
	_msg_error "Patch did not pass verification, cannot proceed" 65 # EX_DATAERR
    fi

    _git_checkout_branch ${_branch}

    _msg_info "Will now apply the patch to branch '${_branch}'"
    git am -q --3way ${_patch}
    
    _sha1_id=$( git rev-parse --verify --short HEAD )
    _msg_info "Tagging commit '${_sha1_id}' as '${_tag}'"
    git tag ${_tag} ${_sha1_id}

    _git_push_branch ${_branch}

    # pull on the Cfengine servers
    exec_pull

    _git_checkout_branch ${_prev_branch}
    _msg_info "Done."
}

# Display usage information for 'git change squash'
# return: EX_USAGE
usage_squash() {
    
    echo "usage: git change squash -b <branch>"
    echo ""
    echo "Creates a patch from a squashed merge against a specified branch"
    echo ""
    echo "This command will perform a squashed merge on a temporary branch,"
    echo "ask you to put a nice commit message, and then generate a patch"
    echo "against the branch specified by <branch>"
    echo ""
    echo "The patch will be saved in your working directory"
    echo ""
    echo "Example usage: git change squash -b STABLE"
    
    exit 64 # EX_USAGE
}

# Prepare a patch against a specified branch
# $1: Branch name [ -b <branch> ]
exec_squash() {
    local _branch
    local _cmd_out
    local _commit_msg
    local _patch_saved
    local _prev_branch=$( git rev-parse --abbrev-ref HEAD )

    # reset getopts
    OPTIND=1

    # Parse command-line options
    while getopts 'b:' arg; do
	case "${arg}" in
            b) _branch="${OPTARG}" ;;
            ?) usage_squash ;;
	esac
    done

    shift $((OPTIND - 1))

    if [[ $# -ne 0 ]]; then
	usage_squash
    fi

    if [[ -z "${_branch}" ]]; then
	usage_squash
    fi

    if ! _git_branch_exists ${_branch} ; then
	_msg_error "The specified branch '${_branch}' does not exists" 65 # EX_DATAERR
    fi

    # verify if squash merge is possible
    if ! _git_verify_merge ${_branch} 1 ; then
	_msg_error "Merge verification failed, cannot proceed" 65 # EX_DATAERR
    else
	_msg_info "Performing the actual merge"
	
	# tmp branch is already updated and originating from ${_branch}
	_git_checkout_branch "tmp"
	git merge -q --squash ${_prev_branch} > /dev/null 2>&1
	
	_msg_info "Will now commit, please make sure to put a nice commit message"
	_yesno_prompt "Press ENTER to continue ..." 2
	
	git commit -q
    
	# patch will be saved in /tmp
	_msg_info "Creating a patch against the '${_branch}' branch"
	
	_commit_msg=$( git log -1 --pretty=%s )
	_patch_saved=$( tr ' ' '-' <<<"${_commit_msg}" )
	_patch_saved=$( tr -d ':' <<<"${_patch_saved}" )
	git format-patch --quiet --stdout ${_branch} > "/tmp/${_patch_saved}.patch"
	
	_msg_info "Patch file saved in /tmp/${_patch_saved}.patch"
	_msg_info "Done."
    fi

    _git_checkout_branch ${_prev_branch}
}

# Display usage information for 'git change revert'
# return: EX_USAGE
usage_revert() {
    
    echo "usage: git change revert -b <branch> -t <tag>"
    echo ""
    echo "Reverts a patch from the specified branch"
    echo ""
    echo "This command will revert the commit tagged as <tag>"
    echo "from the specified branch <branch>"
    echo ""
    echo "Tag objects will be removed from the local and remote"
    echo "repository after the revert"
    echo ""
    echo "Example usage: git change revert -b STABLE -t RFC-WXYZ-STABLE"
    
    exit 64 # EX_USAGE
}

# Revert a patch from a specified branch
# $1: Branch name [ -b <branch> ]
# $2: Tag name [ -t <tag> ]
exec_revert() {
    local _branch
    local _tag
    local _pull
    local _cmd_out
    local _sha1_id
    local _prev_branch=$( git rev-parse --abbrev-ref HEAD )

    # reset getopts
    OPTIND=1

    # Parse command-line options
    while getopts 'b:t:p:' arg; do
	case "${arg}" in
            b) _branch="${OPTARG}" ;;
	    t) _tag="${OPTARG}" ;;
	    p) _pull=${OPTARG} ;;
            ?) usage_revert ;;
	esac
    done

    shift $((OPTIND - 1))

    if [[ $# -ne 0 ]]; then
	usage_revert
    fi

    # check if we have any arguments at all
    if [[ ( -z "${_branch}" ) || ( -z "${_tag}" ) ]]; then
	usage_revert
    fi

    if ! _git_branch_exists ${_branch} ; then
	_msg_error "The specified branch '${_branch}' does not exists" 65 # EX_DATAERR
    fi

    # Verify if the specified tag name exists already
    if ! _git_tag_exists ${_tag} ; then
	_msg_error "The specified tag '${_tag}' does not exists" 0
	_msg_error "Please specify a valid tag name." 65 # EX_DATAERR
    fi

    # Verify if revert is possible
    if ! _git_verify_revert ${_branch} ${_tag} ; then
	_msg_error "Revert verification failed, cannot proceed" 65 # EX_DATAERR
    else
	_git_checkout_branch ${_branch}
    
	_sha1_id=$( git rev-parse --short ${_tag} )
	_msg_info "Reverting commit '${_tag}' [SHA1: ${_sha1_id}]"
	git revert -n ${_sha1_id}

	_msg_info "Will now commit, please make sure to put a nice commit message"
	_yesno_prompt "Press ENTER to continue ..." 2
    
	git commit -q
        
	_git_push_branch ${_branch}
	
	_msg_info "Removing tag '${_tag}' from local repository"
	git tag -d ${_tag} > /dev/null 2>&1
	
	_msg_info "Removing tag '${_tag}' from remote repository"
	git push origin :refs/tags/${_tag} > /dev/null 2>&1
	
	_git_checkout_branch ${_prev_branch}
	
	# should we pull on the Cfengine servers?
	if [ ${_pull} -eq 1 ]; then
	    exec_pull
	fi

	_msg_info "Done."
    fi
}

# Display usage information for 'git change new'
# return: EX_USAGE
usage_new() {
    
    echo "usage: git change new -c <change> -b <branch>"
    echo ""
    echo "Starts off a new branch <change> originating from <branch>"
    echo ""
    echo "This command creates a new branch <change> for you, which"
    echo "originates from <branch>"
    echo ""
    echo "Before creating <change> branch, first <branch> will be"
    echo "automatically synced from the remote origin/<branch>"
    echo "to make sure you have the latest changes"
    echo ""
    echo "Example usage: git change new -c RFC-WXYZ -b STABLE"
    
    exit 64 # EX_USAGE
}

# Starts off a new branch <change> from <branch>
# $1: Change branch [ -c <change> ]
# $2: Branch [ -b <branch> ]
exec_new() {
    local _change="${1}"
    local _branch="${2}"

    # reset getopts
    OPTIND=1

    # Parse command-line options
    while getopts 'c:b:' arg; do
	case "${arg}" in
            c) _change="${OPTARG}" ;;
	    b) _branch="${OPTARG}" ;;
            ?) usage_new ;;
	esac
    done

    shift $((OPTIND - 1))

    if [[ $# -ne 0 ]]; then
	usage_new
    fi

    # check if we have any arguments at all
    if [[ ( -z "${_change}" ) || ( -z "${_branch}" ) ]]; then
	usage_new
    fi

    if ! _git_branch_exists ${_branch} ; then
	_msg_error "The specified branch '${_branch}' does not exists" 65 # EX_DATAERR
    fi

    if _git_branch_exists ${_change} ; then
	_msg_error "The specified branch '${_change}' already exists" 65 # EX_DATAERR
    fi

    _git_update_branch ${_branch}

    _msg_info "Creating a new branch '${_change}'"
    git checkout -b ${_change} ${_branch} > /dev/null 2>&1
    
    _git_push_branch ${_change}
    
    _msg_info "Setting up upstream branch for '${_change}' to 'origin/${_change}'"
    git branch --set-upstream ${_change} origin/${_change} > /dev/null 2>&1

    _msg_info "You are now working on the '${_change}' branch"
    _msg_info "Done."
}

# Display usage information for 'git change sync'
# return: EX_USAGE
usage_sync() {
    
    echo "usage: git change sync -b <branch>"
    echo ""
    echo "Syncs the current branch against the specified <branch>"
    echo ""
    echo "This command syncs the current branch against <branch>"
    echo "using git-rebase(8)"
    echo ""
    echo "Example usage: git change sync -b STABLE"
    
    exit 64 # EX_USAGE
}

# Syncs the current branch against a specified <branch>
# $1: Branch [ -b <branch> ]
exec_sync() {
    local _branch="${1}"
    local _interactive=$2
    local _prev_branch=$( git rev-parse --abbrev-ref HEAD )
    local _sync_opts
    local _cmd_out
    local _rc

    # reset getopts
    OPTIND=1

    # Parse command-line options
    while getopts 'b:i:' arg; do
	case "${arg}" in
	    b) _branch="${OPTARG}" ;;
	    i) _interactive=${OPTARG} ;;
            ?) usage_sync ;;
	esac
    done

    shift $((OPTIND - 1))

    if [[ $# -ne 0 ]]; then
	usage_sync
    fi

    # check if we have any arguments at all
    if [[ -z "${_branch}" ]]; then
	usage_sync
    fi

    if ! _git_branch_exists ${_branch} ; then
	_msg_error "The specified branch '${_branch}' does not exists" 65 # EX_DATAERR
    fi

    if ! _git_verify_rebase ${_branch} ; then
	_msg_error "Sync verification did not pass, cannot proceed" 65 # EX_DATAERR
    else
	_msg_info "Doing the actual sync"
	git rebase -q ${_branch} 
	_msg_info "Done."
    fi
}

# Display usage information for 'git change pull'
# return: EX_USAGE
usage_pull() {
    
    echo "usage: git change pull"
    echo ""
    echo "Performs a pull operation on the Cfengine servers"
    echo ""
    echo "This command will perform a 'git pull' on the Cfengine servers"
    echo ""
    echo "Example usage: git change pull"
    
    exit 64 # EX_USAGE
}

# Pull changes on the Cfengine servers
exec_pull() {
    local _cfengine_servers="cfengine-test.elex.be cfengine-uat.elex.be cfengine.elex.be"
    local _server

    if [ $# -ne 0 ]; then
	usage_pull
    fi

    for _server in ${_cfengine_servers}; do 
	_msg_info "Pulling on '${_server}'"
	ssh ${USER}@"${_server}" "cd /var/lib/cfengine2 && sudo git pull" > /dev/null 2>&1
    done
}

# Display usage information for 'git change init'
# return: EX_USAGE
usage_init() {
    
    echo "usage: git change init"
    echo ""
    echo "Performs initial setup of the helpers"
    echo ""
    echo "Initial setup of the helpers consists of creating a home"
    echo "folder for you and copying your public SSH keys to the"
    echo "master Cfengine servers"
    echo ""
    echo "Example usage: git change init"
    
    exit 64 # EX_USAGE
}

# Performs initial configuration of the helpers
exec_init() {
    local _cfengine_servers="cfengine-test.elex.be cfengine-uat.elex.be cfengine.elex.be"
    local _server
    local _username
    local _ssh_key

    if [ $# -ne 0 ]; then
	usage_init
    fi

    _msg_info "Performing initial setup of the helpers"
    read -p "Username to use [default ${USER}]: " _username

    if [[ -z "${_username}" ]]; then
	_username=${USER}
    fi

    if [[ -e "/home/${_username}/.ssh/id_rsa.pub" ]]; then
	_ssh_key="/home/${_username}/.ssh/id_rsa.pub"
    elif [[ -e "/home/${_username}/.ssh/id_dsa.pub" ]]; then
	_ssh_key="/home/${_username}/.ssh/id_dsa.pub"
    else
	_msg_info "There were no public SSH keys found in /home/${_username}/.ssh"
	_msg_info "Executing ssh-keygen(1)"
	ssh-keygen -t rsa -b 2048
	_ssh_key="/home/${_username}/.ssh/id_rsa.pub"
    fi

    for _server in ${_cfengine_servers}; do 
	_msg_info "Configuring access to '${_server}'"
	ssh-copy-id "${_username}"@"${_server}"
    done
}

# Main command 'git change'
# $*: Command name, options and arguments
exec_git_change() { 
    local _cmd_name

    # Check if any command was specified on the command-line
    if [[ $# -lt 1 ]]; then
	_msg_error "No command specified" 0
	_usage
    fi

    _cmd_name="${1}"
    shift

    _sanity_check

    case "${_cmd_name}" in
	verify)
	    exec_verify $*
	    ;;
	apply)
	    exec_apply $*
	    ;;
	pull)
	    exec_pull $*
	    ;;
	squash)
	    exec_squash $*
	    ;;
	revert)
	    exec_revert $* -p 1
	    ;;
	new)
	    exec_new $*
	    ;;
	sync)
	    exec_sync $*
	    ;;
	init)
	    exec_init $*
	    ;;
	help)
	    # Display the available commands
	    if [[ $# -eq 0 ]]; then
		_msg_info "The following commands are available:"
		
		echo ""
		echo $"${COMMANDS}"
		echo ""
		
		_msg_info "For more infomation on a command see 'git change help <command>'"
		exit 0 # EX_OK
	    elif [[ $# -eq 1 ]]; then
		# Display the usage information about the requested command
		_exec_help "${1}"
	    else
		_msg_error "You need to specify one command name only" 0
		_msg_error "Please check 'git change help' for more information" 64 # EX_USAGE
	    fi
	    ;;
	*)
	    _msg_error "'${_cmd_name}' is not a valid command." 0
	    _msg_error "See 'git change help' for more information on the commands." 64 # EX_USAGE
	    ;;
    esac

    exit 0 # EX_OK
}

git config --global alias.change '! f() { eval bash -ic \"{ exec_git_change $* \; }\" ; } ; f'

