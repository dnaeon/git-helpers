## Git helpers

*git-helpers* is a collection of shell functions which purpose is to
automate the process of deploying changes from one branch to another easier using patches.

## Commands supported

The following commands are currently supported by the *git-helpers*:

	apply   Applies a patch to the specified branch
	init    Perform initial setup of the helpers
    new     Starts off a new change
	pull    Performs a pull on the Cfengine servers
	revert  Reverts a change from the specified branch
	squash  Creates a patch from a squashed merge against a specified branch
	sync    Syncs a branch using rebase
	verify  Verifies a patch against the specified branch
	
## Installing the helpers

In order to install the helpers follow the instructions below.

Clone the Git repository.

Add to your shell profile, e.g. ~/.bashrc a line to source the helpers

	source /path/to/git-helpers/git-helpers.sh

And that's it.

## Using the helpers

In order to use the helpers execute the `git change` command, which is a Git alias for the helpers.

To get usage information about a subcommand execute `git change help <subcommand>`

