# vim:et:ft=sh:sts=2:sw=2

##############################################################################
# @file   shflags.sh
# @author Kate Ward <kate.ward at forestent.com>, Andreas Schuh
# @brief  Advanced command-line flag library for Unix shell scripts.
#
# @sa http://code.google.com/p/shflags/
#
# @note The shFlags implementation by Kate Ward (revision 147) has been
#       considerably modified by Andreas Schuh as part of the BASIS project
#       to fit the needs of the SBIA Group at The University of Pennsylvania.
#
# This module implements something like the google-gflags library available
# from http://code.google.com/p/google-gflags/.
#
# FLAG TYPES: This is a list of the DEFINE_*'s that you can do.  All flags take
# a name, default value, help-string, and optional 'short' name (one-letter
# name).  Some flags have other arguments, which are described with the flag.
#
# - DEFINE_string: takes any input, and intreprets it as a string.
#
# - DEFINE_boolean: typically does not take any argument: say --myflag to set
#   FLAGS_myflag to true, or --nomyflag to set FLAGS_myflag to false.
#   Alternatively, you can say
#     --myflag=true  or --myflag=t or --myflag=0  or
#     --myflag=false or --myflag=f or --myflag=1
#   Passing an option has the same affect as passing the option once.
#
# - DEFINE_float: takes an input and intreprets it as a floating point number. As
#   shell does not support floats per-se, the input is merely validated as
#   being a valid floating point value.
#
# - DEFINE_integer: takes an input and intreprets it as an integer.
#
# - SPECIAL FLAGS: There are a few flags that have special meaning:
#   --help (or -?)  prints a list of all the flags in a human-readable fashion
#   --flagfile=foo  read flags from foo.  (not implemented yet)
#   --              as in getopt(), terminates flag-processing
#
# EXAMPLE USAGE:
#
# Example script hello.sh(.in):
# @code
# #! /bin/sh
# @BASIS_BASH_UTILITIES@
#
# DEFINE_string name 'world' "somebody's name" n
#
# FLAGS "$@" || exit $?
# eval set -- "${FLAGS_ARGV}"
#
# echo "Hello, ${FLAGS_name}."
# @endcode
#
# Usage of example script hello.sh:
# @code
# $ ./hello.sh -n Kate
# Hello, Kate.
# @endcode
#
# CUSTOMIZABLE BEHAVIOR:
#
# A script can override the default 'getopt' command by providing the path to
# an alternate implementation by defining the FLAGS_GETOPT_CMD variable.
#
# ATTRIBUTES:
#
# Shared attributes:
#   flags_error: last error message
#   flags_return: last return value
#
#   __flags_longNames: list of long names for all flags
#   __flags_shortNames: list of short names for all flags
#   __flags_boolNames: list of boolean flag names
#
#   __flags_opts: options parsed by getopt
#
# Per-flag attributes:
#   FLAGS_<flag_name>: contains value of flag named 'flag_name'
#   __flags_<flag_name>_default: the default flag value
#   __flags_<flag_name>_help: the flag help string
#   __flags_<flag_name>_short: the flag short name
#   __flags_<flag_name>_type: the flag type
#   __flags_<flag_name>_category: category of flag, use special category
#                                 'required' to denote flags that need to be
#                                 given on the command line
#
# NOTES:
#
# - Not all systems include a getopt version that supports long flags. On these
#   systems, only short flags are recognized.
#
# - Lists of strings are space separated, and a null value is the '~' char.
#
# Copyright 2008 Kate Ward.
# Copyright 2011 University of Pennsylvania.
# All Rights Reserved.
#
# Released under the LGPL (GNU Lesser General Public License)
#
# @ingroup BashUtilities

# return if FLAGS already loaded
[ -n "${FLAGS_VERSION:-}" ] && return 0

FLAGS_VERSION='1.0.4pre-sbia'

# ============================================================================
# variables
# ============================================================================

# a user can set the path to a different getopt command by overriding this
# variable in their script
FLAGS_GETOPT_CMD=${FLAGS_GETOPT_CMD:-getopt}

# return values that scripts can use
FLAGS_TRUE=0
FLAGS_FALSE=1
FLAGS_ERROR=2

# logging functions
_flags_debug() { echo "flags:DEBUG $@" >&2; }
_flags_warn() { echo "flags:WARN $@" >&2; }
_flags_error() { echo "flags:ERROR $@" >&2; }
_flags_fatal() { echo "flags:FATAL $@" >&2; exit ${FLAGS_ERROR}; }

# specific shell checks
if [ -n "${ZSH_VERSION:-}" ]; then
  setopt |grep "^shwordsplit$" >/dev/null
  if [ $? -ne ${FLAGS_TRUE} ]; then
    _flags_fatal 'zsh shwordsplit option is required for proper zsh operation'
  fi
  if [ -z "${FLAGS_PARENT:-}" ]; then
    _flags_fatal "zsh does not pass \$0 through properly. please declare' \
\"FLAGS_PARENT=\$0\" before calling shFlags"
  fi
fi

# ----------------------------------------------------------------------------
# constants
# ----------------------------------------------------------------------------

# reserved flag names
__FLAGS_RESERVED_LIST=' ARGC ARGV ERROR FALSE GETOPT_CMD HELP PARENT TRUE '
__FLAGS_RESERVED_LIST="${__FLAGS_RESERVED_LIST} VERSION "

# getopt version
__FLAGS_GETOPT_VERS_STD=0
__FLAGS_GETOPT_VERS_ENH=1
__FLAGS_GETOPT_VERS_BSD=2

${FLAGS_GETOPT_CMD} >/dev/null 2>&1
case $? in
  0) __FLAGS_GETOPT_VERS=${__FLAGS_GETOPT_VERS_STD} ;;  # bsd getopt
  2)
    # TODO(kward): look into '-T' option to test the internal getopt() version
    if [ "`${FLAGS_GETOPT_CMD} --version`" = '-- ' ]; then
      __FLAGS_GETOPT_VERS=${__FLAGS_GETOPT_VERS_STD}
    else
      __FLAGS_GETOPT_VERS=${__FLAGS_GETOPT_VERS_ENH}
    fi
    ;;
  *) _flags_fatal 'unable to determine getopt version' ;;
esac

# getopt optstring lengths
__FLAGS_OPTSTR_SHORT=0
__FLAGS_OPTSTR_LONG=1

__FLAGS_NULL='~'

# flag info strings
__FLAGS_INFO_DEFAULT='default'
__FLAGS_INFO_HELP='help'
__FLAGS_INFO_SHORT='short'
__FLAGS_INFO_TYPE='type'
__FLAGS_INFO_CATEGORY='category'

# flag lengths
__FLAGS_LEN_SHORT=0
__FLAGS_LEN_LONG=1

# flag types
__FLAGS_TYPE_NONE=0
__FLAGS_TYPE_BOOLEAN=1
__FLAGS_TYPE_FLOAT=2
__FLAGS_TYPE_INTEGER=3
__FLAGS_TYPE_UNSIGNED_INTEGER=4
__FLAGS_TYPE_STRING=5
__FLAGS_TYPE_COUNTER=6

# set the constants readonly
__flags_constants=`set |awk -F= '/^FLAGS_/ || /^__FLAGS_/ {print $1}'`
for __flags_const in ${__flags_constants}; do
  # skip certain flags
  case ${__flags_const} in
    FLAGS_PARENT) continue ;;
  esac
  # set flag readonly
  if [ -z "${ZSH_VERSION:-}" ]; then
    readonly ${__flags_const}
  else  # handle zsh
    case ${ZSH_VERSION} in
      [123].*) readonly ${__flags_const} ;;
      *) readonly -g ${__flags_const} ;;  # declare readonly constants globally
    esac
  fi
done
unset __flags_const __flags_constants

# ----------------------------------------------------------------------------
# internal variables
# ----------------------------------------------------------------------------

# space separated lists
__flags_boolNames=' '    # boolean flag names
__flags_longNames=' '    # long flag names
__flags_shortNames=' '   # short flag names
__flags_definedNames=' ' # defined flag names (used for validation)

# arrays
__flags_categoryNames=() # flag category names

# others
__flags_columns='' # determined screen width in columns
__flags_opts=''    # temporary storage for parsed getopt flags

# ============================================================================
# private functions
# ============================================================================

# Define a flag.
#
# Calling this function will define the following info variables for the
# specified flag:
#   FLAGS_flagname - the name for this flag (based upon the long flag name)
#   __flags_<flag_name>_default - the default value
#   __flags_<flag_name>_help - the help string
#   __flags_<flag_name>_short - the single letter alias
#   __flags_<flag_name>_type - the type of flag (one of __FLAGS_TYPE_*)
#   __flags_<flag_name>_category - the category of the flag
#
# Args:
#   _flags_type: integer: internal type of flag (__FLAGS_TYPE_*)
#   _flags_name: string: long flag name
#   _flags_default: default flag value
#   _flags_help: string: help string
#   _flags_short: string: (optional) short flag name
#   _flags_category: string: (optional) category name this flags belongs to
# Returns:
#   integer: success of operation, or error
_flags_define()
{
  if [ $# -lt 4 ]; then
    flags_error='DEFINE error: too few arguments'
    flags_return=${FLAGS_ERROR}
    _flags_error "${flags_error}"
    return ${flags_return}
  fi

  _flags_type_=$1
  _flags_name_=$2
  _flags_default_=$3
  _flags_help_=$4
  _flags_short_=${5:-${__FLAGS_NULL}}
  _flags_category_=${6:-${__FLAGS_NULL}}

  _flags_return_=${FLAGS_TRUE}
  _flags_usName_=`_flags_underscoreName ${_flags_name_}`

  # check whether the flag name is reserved
  _flags_itemInList ${_flags_usName_} "${__FLAGS_RESERVED_LIST}"
  if [ $? -eq ${FLAGS_TRUE} ]; then
    flags_error="flag name (${_flags_name_}) is reserved"
    _flags_return_=${FLAGS_ERROR}
  fi

  # require short option for getopt that don't support long options
  if [ ${_flags_return_} -eq ${FLAGS_TRUE} \
      -a ${__FLAGS_GETOPT_VERS} -ne ${__FLAGS_GETOPT_VERS_ENH} \
      -a "${_flags_short_}" = "${__FLAGS_NULL}" ]
  then
    flags_error="short flag required for (${_flags_name_}) on this platform"
    _flags_return_=${FLAGS_ERROR}
  fi

  # check for existing long name definition
  if [ ${_flags_return_} -eq ${FLAGS_TRUE} ]; then
    if _flags_itemInList ${_flags_usName_} ${__flags_definedNames}; then
      flags_error="definition for ([no]${_flags_name_}) already exists"
      _flags_warn "${flags_error}"
      _flags_return_=${FLAGS_FALSE}
    fi
  fi

  # check for existing short name definition
  if [ ${_flags_return_} -eq ${FLAGS_TRUE} \
      -a "${_flags_short_}" != "${__FLAGS_NULL}" ]
  then
    if _flags_itemInList "${_flags_short_}" ${__flags_shortNames}; then
      flags_error="flag short name (${_flags_short_}) already defined"
      _flags_warn "${flags_error}"
      _flags_return_=${FLAGS_FALSE}
    fi
  fi

  # handle default value. note, on several occasions the 'if' portion of an
  # if/then/else contains just a ':' which does nothing. a binary reversal via
  # '!' is not done because it does not work on all shells.
  if [ ${_flags_return_} -eq ${FLAGS_TRUE} ]; then
    case ${_flags_type_} in
      ${__FLAGS_TYPE_BOOLEAN})
        if _flags_validateBoolean "${_flags_default_}"; then
          case ${_flags_default_} in
            true|t|0) _flags_default_=${FLAGS_TRUE} ;;
            false|f|1) _flags_default_=${FLAGS_FALSE} ;;
          esac
        else
          flags_error="${_flags_name_}: invalid default flag value '${_flags_default_}'"
          _flags_return_=${FLAGS_ERROR}
        fi
        ;;

      ${__FLAGS_TYPE_FLOAT})
        if _flags_validateFloat "${_flags_default_}"; then
          :
        else
          flags_error="${_flags_name_}: invalid default flag value '${_flags_default_}'"
          _flags_return_=${FLAGS_ERROR}
        fi
        ;;

      ${__FLAGS_TYPE_INTEGER})
        if _flags_validateInteger "${_flags_default_}"; then
          :
        else
          flags_error="${_flags_name_}: invalid default flag value '${_flags_default_}'"
          _flags_return_=${FLAGS_ERROR}
        fi
        ;;

      ${__FLAGS_TYPE_UNSIGNED_INTEGER}|${__FLAGS_TYPE_COUNTER})
        if _flags_validateUnsignedInteger "${_flags_default_}"; then
          :
        else
          flags_error="${_flags_name_}: invalid default flag value '${_flags_default_}'"
          _flags_return_=${FLAGS_ERROR}
        fi
        ;;

      ${__FLAGS_TYPE_STRING}) ;;  # everything in shell is a valid string

      *)
        flags_error="${_flags_name_}: unrecognized flag type '${_flags_type_}'"
        _flags_return_=${FLAGS_ERROR}
        ;;
    esac
  fi

  if [ ${_flags_return_} -eq ${FLAGS_TRUE} ]; then
    # store flag information
    eval "FLAGS_${_flags_usName_}='${_flags_default_}'"
    eval "__flags_${_flags_usName_}_${__FLAGS_INFO_TYPE}=${_flags_type_}"
    eval "__flags_${_flags_usName_}_${__FLAGS_INFO_DEFAULT}=\"${_flags_default_}\""
    eval "__flags_${_flags_usName_}_${__FLAGS_INFO_HELP}=\"${_flags_help_}\""
    eval "__flags_${_flags_usName_}_${__FLAGS_INFO_SHORT}='${_flags_short_}'"
    eval "__flags_${_flags_usName_}_${__FLAGS_INFO_CATEGORY}='${_flags_category_}'"

    # append flag names to name lists
    __flags_shortNames="${__flags_shortNames}${_flags_short_} "
    __flags_longNames="${__flags_longNames}${_flags_name_} "
    [ ${_flags_type_} -eq ${__FLAGS_TYPE_BOOLEAN} ] && \
        __flags_boolNames="${__flags_boolNames}no${_flags_name_} "

    # append flag names to defined names for later validation checks
    __flags_definedNames="${__flags_definedNames}${_flags_usName_} "
    [ ${_flags_type_} -eq ${__FLAGS_TYPE_BOOLEAN} ] && \
        __flags_definedNames="${__flags_definedNames}no${_flags_usName_} "

    # append category name to category names list
    if [ "${_flags_category_}" != "${__FLAGS_NULL}" ]; then
      _flags_found_=${FLAGS_FALSE}
      for _flags_categoryName_ in "${__flags_categoryNames[@]}"; do
        if [ "${_flags_categoryName_}" = "${_flags_category_}" ]; then
          _flags_found_=${FLAGS_TRUE}
          break
        fi
      done
      if [ ${_flags_found_} -eq ${FLAGS_FALSE} ]; then
        __flags_categoryNames[${#__flags_categoryNames[@]}]="${_flags_category_}"
      fi
    fi
  fi

  flags_return=${_flags_return_}
  unset _flags_default_ _flags_help_ _flags_name_ _flags_return_ \
      _flags_short_ _flags_type_ _flags_usName_ \
      _flags_category_ _flags_found_
  [ ${flags_return} -eq ${FLAGS_ERROR} ] && _flags_error "${flags_error}"
  return ${flags_return}
}


# Return valid getopt options using currently defined list of long options.
#
# This function builds a proper getopt option string for short (and long)
# options, using the current list of long options for reference.
#
# Args:
#   _flags_optStr: integer: option string type (__FLAGS_OPTSTR_*)
# Output:
#   string: generated option string for getopt
# Returns:
#   boolean: success of operation (always returns True)
_flags_genOptStr()
{
  _flags_optStrType_=$1

  _flags_opts_=''

  for _flags_name_ in ${__flags_longNames}; do
    _flags_usName_=`_flags_underscoreName ${_flags_name_}`
    _flags_type_=`_flags_getFlagInfo ${_flags_usName_} ${__FLAGS_INFO_TYPE}`
    [ $? -eq ${FLAGS_TRUE} ] || _flags_fatal 'call to _flags_type_ failed'
    case ${_flags_optStrType_} in
      ${__FLAGS_OPTSTR_SHORT})
        _flags_shortName_=`_flags_getFlagInfo \
            ${_flags_usName_} ${__FLAGS_INFO_SHORT}`
        if [ "${_flags_shortName_}" != "${__FLAGS_NULL}" ]; then
          _flags_opts_="${_flags_opts_}${_flags_shortName_}"
          # getopt needs a trailing ':' to indicate a required argument
          [ ${_flags_type_} -ne ${__FLAGS_TYPE_BOOLEAN} -a \
            ${_flags_type_} -ne ${__FLAGS_TYPE_COUNTER} ] && \
              _flags_opts_="${_flags_opts_}:"
        fi
        ;;

      ${__FLAGS_OPTSTR_LONG})
        _flags_opts_="${_flags_opts_:+${_flags_opts_},}${_flags_name_}"
        # getopt needs a trailing ':' to indicate a required argument
        [ ${_flags_type_} -ne ${__FLAGS_TYPE_BOOLEAN} -a \
          ${_flags_type_} -ne ${__FLAGS_TYPE_COUNTER} ] && \
            _flags_opts_="${_flags_opts_}:"
        ;;
    esac
  done

  echo "${_flags_opts_}"
  unset _flags_name_ _flags_opts_ _flags_optStrType_ _flags_shortName_ \
      _flags_type_ _flags_usName_
  return ${FLAGS_TRUE}
}

# Returns flag details based on a flag name and flag info.
#
# Args:
#   string: underscored flag name
#   string: flag info (see the _flags_define function for valid info types)
# Output:
#   string: value of dereferenced flag variable
# Returns:
#   integer: one of FLAGS_{TRUE|FALSE|ERROR}
_flags_getFlagInfo()
{
  # note: adding gFI to variable names to prevent naming conflicts with calling
  # functions
  _flags_gFI_usName_=$1
  _flags_gFI_info_=$2

  _flags_infoVar_="__flags_${_flags_gFI_usName_}_${_flags_gFI_info_}"
  _flags_strToEval_="_flags_infoValue_=\"\${${_flags_infoVar_}:-}\""
  eval "${_flags_strToEval_}"
  if [ -n "${_flags_infoValue_}" ]; then
    flags_return=${FLAGS_TRUE}
  else
    # see if the _flags_gFI_usName_ variable is a string as strings can be
    # empty...
    # note: the DRY principle would say to have this function call itself for
    # the next three lines, but doing so results in an infinite loop as an
    # invalid _flags_name_ will also not have the associated _type variable.
    # Because it doesn't (it will evaluate to an empty string) the logic will
    # try to find the _type variable of the _type variable, and so on. Not so
    # good ;-)
    _flags_typeVar_="__flags_${_flags_gFI_usName_}_${__FLAGS_INFO_TYPE}"
    _flags_strToEval_="_flags_typeValue_=\"\${${_flags_typeVar_}:-}\""
    eval "${_flags_strToEval_}"
    if [ "${_flags_typeValue_}" = "${__FLAGS_TYPE_STRING}" ]; then
      flags_return=${FLAGS_TRUE}
    else
      flags_return=${FLAGS_ERROR}
      flags_error="missing flag info variable (${_flags_infoVar_})"
    fi
  fi

  echo "${_flags_infoValue_}"
  unset _flags_gFI_usName_ _flags_gfI_info_ _flags_infoValue_ _flags_infoVar_ \
      _flags_strToEval_ _flags_typeValue_ _flags_typeVar_
  [ ${flags_return} -eq ${FLAGS_ERROR} ] && _flags_error "${flags_error}"
  return ${flags_return}
}

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

# Underscore a flag or category name by replacing dashes and whitespaces with underscores.
#
# Args:
#   unnamed: string: long flag or category name
# Output:
#   string: underscored name
_flags_underscoreName()
{
  echo $1 | sed 's/[ -]/_/g'
}

# Escape string for use in XML output.
#
# Args:
#   unnamed: string: some string
# Output:
#   string: xml-escaped string
_flags_xmlText()
{
  echo -e "$1" | sed 's/\&/\&amp;/g;s/</\&lt;/g'
}

# Escape string for use in man page output.
#
# Args:
#   unnamed: string: some string
# Output:
#   string: man page-escaped string
_flags_manText()
{
  echo -e "$1" | sed 's/\\/\\\\/g;s/-/\\-/g'
}

# Returns the width of the current screen.
#
# Output:
#   integer: width in columns of the current screen.
_flags_columns()
{
  if [ -z "${__flags_columns}" ]; then
    # determine the value and store it
    if eval stty size >/dev/null 2>&1; then
      # stty size worked :-)
      set -- `stty size`
      __flags_columns=$2
    elif eval tput cols >/dev/null 2>&1; then
      set -- `tput cols`
      __flags_columns=$1
    else
      __flags_columns=80  # default terminal width
    fi
  fi
  echo ${__flags_columns}
}

# Check for presense of item in a list.
#
# Passed a string (e.g. 'abc'), this function will determine if the string is
# present in the list of strings (e.g.  ' foo bar abc ').
#
# Args:
#   _flags_str_: string: string to search for in a list of strings
#   unnamed: list: list of strings
# Returns:
#   boolean: true if item is in the list
_flags_itemInList()
{
  _flags_str_=$1
  shift

  echo " ${*:-} " |grep " ${_flags_str_} " >/dev/null
  if [ $? -eq 0 ]; then
    flags_return=${FLAGS_TRUE}
  else
    flags_return=${FLAGS_FALSE}
  fi

  unset _flags_str_
  return ${flags_return}
}

# Sort space separated list.
#
# Args:
#   @: list: space separated list of strings
# Output:
#   list: sorted space separated list of strings
_flags_sortList()
{
  echo "$@" | tr ' ' '\n' | sort | tr '\n' ' '
}

# ----------------------------------------------------------------------------
# validators
# ----------------------------------------------------------------------------

# Validate a boolean.
#
# Args:
#   _flags__bool: boolean: value to validate
# Returns:
#   bool: true if the value is a valid boolean
_flags_validateBoolean()
{
  _flags_bool_=$1

  flags_return=${FLAGS_TRUE}
  case "${_flags_bool_}" in
    true|t|0) ;;
    false|f|1) ;;
    *) flags_return=${FLAGS_FALSE} ;;
  esac

  unset _flags_bool_
  return ${flags_return}
}

# Validate a float.
#
# Args:
#   _flags__float: float: value to validate
# Returns:
#   bool: true if the value is a valid float
_flags_validateFloat()
{
  _flags_float_=$1

  if _flags_validateInteger ${_flags_float_}; then
    flags_return=${FLAGS_TRUE}
  else
    flags_return=${FLAGS_TRUE}
    case ${_flags_float_} in
      -*)  # negative floats
        _flags_test_=`expr -- "${_flags_float_}" :\
            '\(-[0-9][0-9]*\.[0-9][0-9]*\)'`
        ;;
      *)  # positive floats
        _flags_test_=`expr -- "${_flags_float_}" :\
            '\([0-9][0-9]*\.[0-9][0-9]*\)'`
        ;;
    esac
    [ "${_flags_test_}" != "${_flags_float_}" ] && flags_return=${FLAGS_FALSE}
  fi

  unset _flags_float_ _flags_test_
  return ${flags_return}
}

# Validate an integer.
#
# Args:
#   _flags__int_: interger: value to validate
# Returns:
#   bool: true if the value is a valid integer
_flags_validateInteger()
{
  _flags_int_=$1

  flags_return=${FLAGS_TRUE}
  case ${_flags_int_} in
    -*)  # negative ints
      _flags_test_=`expr -- "${_flags_int_}" : '\(-[0-9][0-9]*\)'`
      ;;
    *)  # positive ints
      _flags_test_=`expr -- "${_flags_int_}" : '\([0-9][0-9]*\)'`
      ;;
  esac
  [ "${_flags_test_}" != "${_flags_int_}" ] && flags_return=${FLAGS_FALSE}

  unset _flags_int_ _flags_test_
  return ${flags_return}
}

# Validate an unsigned integer.
#
# Args:
#   _flags__uint_: interger: value to validate
# Returns:
#   bool: true if the value is a valid unsigned integer
_flags_validateUnsignedInteger()
{
  _flags_uint_=$1

  flags_return=${FLAGS_TRUE}
  _flags_test_=`expr -- "${_flags_uint_}" : '\([0-9][0-9]*\)'`
  [ "${_flags_test_}" != "${_flags_uint_}" ] && flags_return=${FLAGS_FALSE}

  unset _flags_uint_ _flags_test_
  return ${flags_return}
}

# ----------------------------------------------------------------------------
# helpers for command-line parsing
# ----------------------------------------------------------------------------

# Parse command-line options using the standard getopt.
#
# Note: the flag options are passed around in the global __flags_opts so that
# the formatting is not lost due to shell parsing and such.
#
# Args:
#   @: varies: command-line options to parse
# Returns:
#   integer: a FLAGS success condition
_flags_getoptStandard()
{
  flags_return=${FLAGS_TRUE}
  _flags_shortOpts_=`_flags_genOptStr ${__FLAGS_OPTSTR_SHORT}`

  # check for spaces in passed options
  for _flags_opt_ in "$@"; do
    # note: the silliness with the x's is purely for ksh93 on Ubuntu 6.06
    _flags_match_=`echo "x${_flags_opt_}x" |sed 's/ //g'`
    if [ "${_flags_match_}" != "x${_flags_opt_}x" ]; then
      flags_error='the available getopt does not support spaces in options'
      flags_return=${FLAGS_ERROR}
      break
    fi
  done

  if [ ${flags_return} -eq ${FLAGS_TRUE} ]; then
    __flags_opts=`getopt ${_flags_shortOpts_} $@ 2>&1`
    _flags_rtrn_=$?
    if [ ${_flags_rtrn_} -ne ${FLAGS_TRUE} ]; then
      _flags_warn "${__flags_opts}"
      flags_error='unable to parse provided options with getopt.'
      flags_return=${FLAGS_ERROR}
    fi
  fi

  unset _flags_match_ _flags_opt_ _flags_rtrn_ _flags_shortOpts_
  return ${flags_return}
}

# Parse command-line options using the enhanced getopt.
#
# Note: the flag options are passed around in the global __flags_opts so that
# the formatting is not lost due to shell parsing and such.
#
# Args:
#   @: varies: command-line options to parse
# Returns:
#   integer: a FLAGS success condition
_flags_getoptEnhanced()
{
  flags_return=${FLAGS_TRUE}
  _flags_shortOpts_=`_flags_genOptStr ${__FLAGS_OPTSTR_SHORT}`
  _flags_boolOpts_=`echo "${__flags_boolNames}" \
      |sed 's/^ *//;s/ *$//;s/ /,/g'`
  _flags_longOpts_=`_flags_genOptStr ${__FLAGS_OPTSTR_LONG}`

  __flags_opts=`${FLAGS_GETOPT_CMD} \
      -o ${_flags_shortOpts_} \
      -l "${_flags_longOpts_},${_flags_boolOpts_}" \
      -- "$@" 2>&1`
  _flags_rtrn_=$?
  if [ ${_flags_rtrn_} -ne ${FLAGS_TRUE} ]; then
    _flags_warn "${__flags_opts}"
    flags_error='unable to parse provided options with getopt.'
    flags_return=${FLAGS_ERROR}
  fi

  unset _flags_boolOpts_ _flags_longOpts_ _flags_rtrn_ _flags_shortOpts_
  return ${flags_return}
}

# Dynamically parse a getopt result and set appropriate variables.
#
# This function does the actual conversion of getopt output and runs it through
# the standard case structure for parsing. The case structure is actually quite
# dynamic to support any number of flags.
#
# Args:
#   argc: int: original command-line argument count
#   @: varies: output from getopt parsing
# Returns:
#   integer: a FLAGS success condition
_flags_parseGetopt()
{
  _flags_argc_=$1
  shift

  flags_return=${FLAGS_TRUE}

  if [ ${__FLAGS_GETOPT_VERS} -ne ${__FLAGS_GETOPT_VERS_ENH} ]; then
    set -- $@
  else
    # note the quotes around the `$@' -- they are essential!
    eval set -- "$@"
  fi

  # provide user with number of arguments to shift by later
  # NOTE: the FLAGS_ARGC variable is obsolete as of 1.0.3 because it does not
  # properly give user access to non-flag arguments mixed in between flag
  # arguments. Its usage was replaced by FLAGS_ARGV, and it is being kept only
  # for backwards compatibility reasons.
  FLAGS_ARGC=`expr $# - 1 - ${_flags_argc_}`

  # handle options. note options with values must do an additional shift
  while true; do
    _flags_opt_=$1
    _flags_arg_=${2:-}
    _flags_type_=${__FLAGS_TYPE_NONE}
    _flags_name_=''

    # determine long flag name
    case "${_flags_opt_}" in
      --) shift; break ;;  # discontinue option parsing

      --*)  # long option
        _flags_opt_=`expr -- "${_flags_opt_}" : '--\(.*\)'`
        _flags_len_=${__FLAGS_LEN_LONG}
        if _flags_itemInList "${_flags_opt_}" ${__flags_longNames}; then
          _flags_name_=${_flags_opt_}
        else
          # check for negated long boolean version
          if _flags_itemInList "${_flags_opt_}" ${__flags_boolNames}; then
            _flags_name_=`expr -- "${_flags_opt_}" : 'no\(.*\)'`
            _flags_type_=${__FLAGS_TYPE_BOOLEAN}
            _flags_arg_=${__FLAGS_NULL}
          fi
        fi
        ;;

      -*)  # short option
        _flags_opt_=`expr -- "${_flags_opt_}" : '-\(.*\)'`
        _flags_len_=${__FLAGS_LEN_SHORT}
        if _flags_itemInList "${_flags_opt_}" ${__flags_shortNames}; then
          # yes. match short name to long name. note purposeful off-by-one
          # (too high) with awk calculations.
          _flags_pos_=`echo "${__flags_shortNames}" \
              |awk 'BEGIN{RS=" ";rn=0}$0==e{rn=NR}END{print rn}' \
                  e=${_flags_opt_}`
          _flags_name_=`echo "${__flags_longNames}" \
              |awk 'BEGIN{RS=" "}rn==NR{print $0}' rn="${_flags_pos_}"`
        fi
        ;;
    esac

    # die if the flag was unrecognized
    if [ -z "${_flags_name_}" ]; then
      flags_error="unrecognized option (${_flags_opt_})"
      flags_return=${FLAGS_ERROR}
      break
    fi

    # set new flag value
    _flags_usName_=`_flags_underscoreName ${_flags_name_}`
    [ ${_flags_type_} -eq ${__FLAGS_TYPE_NONE} ] && \
        _flags_type_=`_flags_getFlagInfo \
            "${_flags_usName_}" ${__FLAGS_INFO_TYPE}`
    case ${_flags_type_} in
      ${__FLAGS_TYPE_BOOLEAN})
        if [ ${_flags_len_} -eq ${__FLAGS_LEN_LONG} ]; then
          if [ "${_flags_arg_}" != "${__FLAGS_NULL}" ]; then
            eval "FLAGS_${_flags_usName_}=${FLAGS_TRUE}"
          else
            eval "FLAGS_${_flags_usName_}=${FLAGS_FALSE}"
          fi
        else
          _flags_strToEval_="_flags_val_=\
\${__flags_${_flags_usName_}_${__FLAGS_INFO_DEFAULT}}"
          eval "${_flags_strToEval_}"
          if [ ${_flags_val_} -eq ${FLAGS_FALSE} ]; then
            eval "FLAGS_${_flags_usName_}=${FLAGS_TRUE}"
          else
            eval "FLAGS_${_flags_usName_}=${FLAGS_FALSE}"
          fi
        fi
        ;;

      ${__FLAGS_TYPE_FLOAT})
        if _flags_validateFloat "${_flags_arg_}"; then
          eval "FLAGS_${_flags_usName_}='${_flags_arg_}'"
        else
          flags_error="${_flags_name_}: invalid float value (${_flags_arg_})"
          flags_return=${FLAGS_ERROR}
          break
        fi
        ;;

      ${__FLAGS_TYPE_INTEGER})
        if _flags_validateInteger "${_flags_arg_}"; then
          eval "FLAGS_${_flags_usName_}='${_flags_arg_}'"
        else
          flags_error="${_flags_name_}: invalid integer value (${_flags_arg_})"
          flags_return=${FLAGS_ERROR}
          break
        fi
        ;;

      ${__FLAGS_TYPE_UNSIGNED_INTEGER})
        if _flags_validateUnsignedInteger "${_flags_arg_}"; then
          eval "FLAGS_${_flags_usName_}='${_flags_arg_}'"
        else
          flags_error="${_flags_name_}: invalid unsigned integer value (${_flags_arg_})"
          flags_return=${FLAGS_ERROR}
          break
        fi
        ;;

      ${__FLAGS_TYPE_STRING})
        eval "FLAGS_${_flags_usName_}='${_flags_arg_}'"
        ;;

      ${__FLAGS_TYPE_COUNTER})
        eval "_flags_val_=\${FLAGS_${_flags_usName_}}"
        _flags_val_=`expr "${_flags_val_}" + 1`
        eval "FLAGS_${_flags_usName_}=${_flags_val_}"
        ;;
    esac

    # handle special case help flag
    if [ "${_flags_usName_}" = 'help' ]; then
      if [ ${FLAGS_help} -eq ${FLAGS_TRUE} ]; then
        flags_help
        flags_error='help requested'
        flags_return=${FLAGS_TRUE}
        break
      fi
    fi

    # handle special case helpman flag
    if [ "${_flags_usName_}" = 'helpman' ]; then
      if [ ${FLAGS_helpman} -eq ${FLAGS_TRUE} ]; then
        # if man should not be executed directory,
        # print generated man page to STDOUT instead
        if [ -n "${FLAGS_execman}" ] && [ ${FLAGS_execman} -eq ${FLAGS_FALSE} ]; then
          flags_helpman
          flags_error='help requested'
          flags_return=${FLAGS_TRUE}
          break
        fi
        # save generated man page to temporary file
        flags_manFile_="`mktemp -t \"${0##*/}.1\"`"
        if [ $? -ne 0 ]; then
          flags_error='failed to create temporary man page file name'
          flags_return=${FLAGS_ERROR}
          break
        fi
        flags_man_="`flags_helpman`"
        if [ $? -ne ${FLAGS_TRUE} ]; then
          flags_error='failed to generate temporary man page file'
          flags_return=${FLAGS_ERROR}
          break
        fi
        echo "${flags_man_}" > "${flags_manFile_}"
        if [ $? -ne ${FLAGS_TRUE} ]; then
          flags_error='failed to write temporary man page file'
          flags_return=${FLAGS_ERROR}
          break
        fi
        # execute man to view the man page
        man "${flags_manFile_}"
        if [ $? -ne ${FLAGS_TRUE} ]; then
          flags_error='failed to execute man to view generated man page'
          flags_return=${FLAGS_ERROR}
        fi
        # remove temporary man page file
        rm -f "${flags_manFile_}"
        if [ ${flags_return} -ne ${FLAGS_ERROR} -a $? -ne ${FLAGS_TRUE} ]; then
          flags_error='failed to execute man to view generated man page'
          flags_return=${FLAGS_ERROR}
        fi
        break
      fi
    fi

    # handle special case helpxml flag
    if [ "${_flags_usName_}" = 'helpxml' ]; then
      if [ ${FLAGS_helpxml} -eq ${FLAGS_TRUE} ]; then
        flags_helpxml
        flags_error='help requested'
        flags_return=${FLAGS_TRUE}
        break
      fi
    fi

    # handle special case usage flag
    if [ "${_flags_usName_}" = 'helpshort' ]; then
      if [ ${FLAGS_helpshort} -eq ${FLAGS_TRUE} ]; then
        flags_helpshort
        flags_error='help requested'
        flags_return=${FLAGS_TRUE}
        break
      fi
    fi

    # handle special case version flag
    if [ "${_flags_usName_}" = 'version' ]; then
      if [ ${FLAGS_version} -eq ${FLAGS_TRUE} ]; then
        flags_version
        flags_error='version requested'
        flags_return=${FLAGS_TRUE}
        break
      fi
    fi

    # shift the option and non-boolean arguments out.
    shift
    [ ${_flags_type_} != ${__FLAGS_TYPE_BOOLEAN} -a \
      ${_flags_type_} != ${__FLAGS_TYPE_COUNTER} ] && shift
  done

  # give user back non-flag arguments
  FLAGS_ARGV=''
  while [ $# -gt 0 ]; do
    FLAGS_ARGV="${FLAGS_ARGV:+${FLAGS_ARGV} }'$1'"
    shift
  done

  unset _flags_arg_ _flags_len_ _flags_name_ _flags_opt_ _flags_pos_ \
      _flags_strToEval_ _flags_type_ _flags_usName_ _flags_val_
  return ${flags_return}
}

# ============================================================================
# public functions
# ============================================================================

# ----------------------------------------------------------------------------
# flag definition
# ----------------------------------------------------------------------------

# A basic boolean flag. Boolean flags do not take any arguments, and their
# value is either 1 (false) or 0 (true). For long flags, the false value is
# specified on the command line by prepending the word 'no'. With short flags,
# the presense of the flag toggles the current value between true and false.
# Specifying a short boolean flag twice on the command results in returning the
# value back to the default value.
#
# A default value is required for boolean flags.
#
# For example, lets say a Boolean flag was created whose long name was 'update'
# and whose short name was 'x', and the default value was 'false'. This flag
# could be explicitly set to 'true' with '--update' or by '-x', and it could be
# explicitly set to 'false' with '--noupdate'.
DEFINE_boolean() { _flags_define ${__FLAGS_TYPE_BOOLEAN} "$@"; }
DEFINE_bool()    { _flags_define ${__FLAGS_TYPE_BOOLEAN} "$@"; }

# Other basic flags.
DEFINE_float()            { _flags_define ${__FLAGS_TYPE_FLOAT} "$@"; }
DEFINE_double()           { _flags_define ${__FLAGS_TYPE_FLOAT} "$@"; }
DEFINE_integer()          { _flags_define ${__FLAGS_TYPE_INTEGER} "$@"; }
DEFINE_int()              { _flags_define ${__FLAGS_TYPE_INTEGER} "$@"; }
DEFINE_unsigned_integer() { _flags_define ${__FLAGS_TYPE_UNSIGNED_INTEGER} "$@"; }
DEFINE_uint()             { _flags_define ${__FLAGS_TYPE_UNSIGNED_INTEGER} "$@"; }
DEFINE_string()           { _flags_define ${__FLAGS_TYPE_STRING} "$@"; }
DEFINE_counter()          { _flags_define ${__FLAGS_TYPE_COUNTER} "$@"; }

# ----------------------------------------------------------------------------
# command-line parsing
# ----------------------------------------------------------------------------

# Parse the flags.
#
# Args:
#   unnamed: list: command-line flags to parse
# Returns:
#   integer: success of operation, or error
FLAGS()
{
  # define standard flags if not already defined
  [ -z "${__flags_help_type:-}" ] && \
      DEFINE_boolean 'help' false 'Show help and exit.' 'h' 'help'
  [ -z "${__flags_helpman_type:-}" -a ${__FLAGS_GETOPT_VERS} -eq ${__FLAGS_GETOPT_VERS_ENH} ] && \
      DEFINE_boolean 'helpman' false 'Show help as man page and exit. If --execman is true (the default),
                                      a temporary man page file is written and displayed using man.
                                      Otherwise, if --noexecman was given before, the generated man
                                      page is printed to stdout instead.' \
          "${__FLAGS_NULL}" 'help'
  [ -z "${__flags_execman_type:-}" -a ${__FLAGS_GETOPT_VERS} -eq ${__FLAGS_GETOPT_VERS_ENH} ] && \
      DEFINE_boolean 'execman' true 'Execute man to view generated man page. See --helpman.' \
          "${__FLAGS_NULL}" 'help'
  [ -z "${__flags_helpxml_type:-}" -a ${__FLAGS_GETOPT_VERS} -eq ${__FLAGS_GETOPT_VERS_ENH} ] && \
      DEFINE_boolean 'helpxml' false 'Output help in XML format and exit.' "${__FLAGS_NULL}" 'help'
  [ -z "${__flags_helpshort_type:-}" -a ${__FLAGS_GETOPT_VERS} -eq ${__FLAGS_GETOPT_VERS_ENH} ] && \
      DEFINE_boolean 'helpshort' false 'Show usage information and exit.' "${__FLAGS_NULL}" 'help'
  [ -z "${__flags_version_type:-}" ] && \
      DEFINE_boolean 'version' false 'Show version and exit.' "${__FLAGS_NULL}" 'help'
  [ -z "${__flags_verbose_type:-}" ] && \
      DEFINE_counter 'verbose' 0 'Increase verbosity of output messages.
                                  Can be given multiple times.' 'v' 'help'

  # parse options
  if [ $# -gt 0 ]; then
    if [ ${__FLAGS_GETOPT_VERS} -ne ${__FLAGS_GETOPT_VERS_ENH} ]; then
      _flags_getoptStandard "$@"
    else
      _flags_getoptEnhanced "$@"
    fi
    flags_return=$?
  else
    # nothing passed; won't bother running getopt
    __flags_opts='--'
    flags_return=${FLAGS_TRUE}
  fi

  if [ ${flags_return} -eq ${FLAGS_TRUE} ]; then
    _flags_parseGetopt $# "${__flags_opts}"
    flags_return=$?
  fi

  [ ${flags_return} -eq ${FLAGS_ERROR} ] && _flags_fatal "${flags_error}"
  return ${flags_return}
}

# ----------------------------------------------------------------------------
# getopt information
# ----------------------------------------------------------------------------

# This is a helper function for determining the 'getopt' version for platforms
# where the detection isn't working. It simply outputs debug information that
# can be included in a bug report.
#
# Args:
#   none
# Output:
#   debug info that can be included in a bug report
# Returns:
#   nothing
flags_getoptInfo()
{
  # platform info
  _flags_debug "uname -a: `uname -a`"
  _flags_debug "PATH: ${PATH}"

  # shell info
  if [ -n "${BASH_VERSION:-}" ]; then
    _flags_debug 'shell: bash'
    _flags_debug "BASH_VERSION: ${BASH_VERSION}"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    _flags_debug 'shell: zsh'
    _flags_debug "ZSH_VERSION: ${ZSH_VERSION}"
  fi

  # getopt info
  ${FLAGS_GETOPT_CMD} >/dev/null
  _flags_getoptReturn=$?
  _flags_debug "getopt return: ${_flags_getoptReturn}"
  _flags_debug "getopt --version: `${FLAGS_GETOPT_CMD} --version 2>&1`"

  unset _flags_getoptReturn
}

# Returns whether the detected getopt version is the enhanced version.
#
# Args:
#   none
# Output:
#   none
# Returns:
#   bool: true if getopt is the enhanced version
flags_getoptIsEnh()
{
  test ${__FLAGS_GETOPT_VERS} -eq ${__FLAGS_GETOPT_VERS_ENH}
}

# Returns whether the detected getopt version is the standard version.
#
# Args:
#   none
# Returns:
#   bool: true if getopt is the standard version
flags_getoptIsStd()
{
  test ${__FLAGS_GETOPT_VERS} -eq ${__FLAGS_GETOPT_VERS_STD}
}

# ----------------------------------------------------------------------------
# help and usage information
# ----------------------------------------------------------------------------

# Prints usage as in synopsis section of man pages.
flags_usage()
{
  flags_requiredFlags_=' '
  flags_optionalFlags_=' '
  for flags_name_ in ${__flags_longNames}; do
    flags_usName_=`_flags_underscoreName ${flags_name_}`
    flags_category_=`_flags_getFlagInfo "${flags_usName_}" ${__FLAGS_INFO_CATEGORY}`
    if [ "${flags_category_}" = 'required' ]; then
      flags_requiredFlags_="${flags_requiredFlags_}${flags_name_} "
    elif [ "${flags_category_}" != 'help' ]; then
      flags_optionalFlags_="${flags_optionalFlags_}${flags_name_} "
    fi
  done

  flags_usage_=''
  if [ -n "${flags_optionalFlags_}" ]; then
    for flags_name_ in ${flags_optionalFlags_}; do
      flags_usName_=`_flags_underscoreName ${flags_name_}`
      flags_type_=`_flags_getFlagInfo "${flags_usName_}" ${__FLAGS_INFO_TYPE}`
      case ${flags_type_} in
        ${__FLAGS_TYPE_BOOLEAN})
          flags_usage_="${flags_usage_} [--[no]${flags_name_}]"
          ;;

        ${__FLAGS_TYPE_FLOAT})
          flags_usage_="${flags_usage_} [--${flags_name_}=<float>]"
          ;;

        ${__FLAGS_TYPE_INTEGER})
          flags_usage_="${flags_usage_} [--${flags_name_}=<int>]"
          ;;

        ${__FLAGS_TYPE_UNSIGNED_INTEGER})
          flags_usage_="${flags_usage_} [--${flags_name_}=<uint>]"
          ;;

        ${__FLAGS_TYPE_STRING})
          flags_usage_="${flags_usage_} [--${flags_name_}=<string>]"
          ;;

        ${__FLAGS_TYPE_COUNTER})
          flags_usage_="${flags_usage_} [--${flags_name_} ...]"
          ;;

        *)
          flags_usage_="${flags_usage_} [--${flags_name_}=<value>]"
          ;;
      esac
    done
  fi
  if [ -n "${flags_requiredFlags_}" ]; then
    for flags_name_ in ${flags_requiredFlags_}; do
      flags_usName_=`_flags_underscoreName ${flags_name_}`
      flags_type_=`_flags_getFlagInfo "${flags_usName_}" ${__FLAGS_INFO_TYPE}`
      case ${flags_type_} in
        ${__FLAGS_TYPE_BOOLEAN})
          flags_usage_="${flags_usage_} --[no]${flags_name_}"
          ;;

        ${__FLAGS_TYPE_FLOAT})
          flags_usage_="${flags_usage_} --${flags_name_}=<float>"
          ;;

        ${__FLAGS_TYPE_INTEGER})
          flags_usage_="${flags_usage_} --${flags_name_}=<int>"
          ;;

        ${__FLAGS_TYPE_UNSIGNED_INTEGER})
          flags_usage_="${flags_usage_} --${flags_name_}=<uint>"
          ;;

        ${__FLAGS_TYPE_STRING})
          flags_usage_="${flags_usage_} --${flags_name_}=<string>"
          ;;

        ${__FLAGS_TYPE_COUNTER})
          flags_usage_="${flags_usage_} [--${flags_name_} ...]"
          ;;

        *)
          flags_usage_="${flags_usage_} --${flags_name_}=<value>"
          ;;
      esac
    done
  fi

  flags_command_=${HELP_COMMAND:-${0##*/}}
  flags_executable_="${FLAGS_PARENT:-${0##*/}}"

  # note: the silliness with the x's is purely for ksh93 on Ubuntu 6.06
  # because it doesn't like empty strings when used in this manner.
  flags_emptyStr_="`echo \"x${flags_executable_}x\" \
      |awk '{printf "%"length($0)+3"s", ""}'`"
  flags_emptyStrLen_=`expr -- "${flags_emptyStr_}" : '.*'`

  flags_usage_="${flags_usage_} args"
  flags_usage_="$(echo "${flags_emptyStr_}${flags_usage_}" | fmt -l 0 -$(_flags_columns))"
  flags_usage_="     ${flags_executable_}${flags_usage_:${flags_emptyStrLen_}}"

  echo "NAME"
  # use first sentence of description as brief description similar to Doxygen
  if [ -n "${HELP_DESCRIPTION}" ]; then
    flags_brief_=${HELP_DESCRIPTION%%.*}
    flags_brief_="$(echo "${flags_brief_}"|sed 's/^\ *//g;s/\ *$//g'|tr '\n' ' ')"
    flags_brief_="     ${flags_command_} -- ${flags_brief_}"
    flags_columns_=`_flags_columns`
    flags_columns_=`expr -- "${flags_columns_}" - 3`
    if [ `expr -- "${flags_brief_}" : '.*'` -gt ${flags_columns_} ]; then
      flags_brief_="${flags_brief_:0:${flags_columns_}}"
      flags_brief_="${flags_brief_% *}..."
    fi
    echo "${flags_brief_}"
  else
    echo "     ${flags_command_}"
  fi
  echo
  echo "SYNOPSIS"
  echo "${flags_usage_}"

  unset flags_name_ flags_command_ flags_usage_ flags_brief_ flags_usName_ \
      flags_executable_ flags_type_ flags_optionalFlags_ flags_requiredFlags_ \
      flags_standardFlags_ flags_emptyStr_ flags_emptyStrLen_ flags_columns_

  return ${FLAGS_TRUE}
}

# Print help for named flag
#
# Args:
#   flags_name_: string: long name of flag
#   flags_maxNameLen: integer: (optional) maximum length of long flag names
#                              used to align help texts (default: 0)
#   flags_showDefault: boolean: (optional) whether to display default value (default: true)
# Returns:
#   integer: success of operation (always returns true)
flags_helpflag()
{
  flags_name_=$1
  flags_maxNameLen=${2:-0}
  flags_showDefault_=${3:-${FLAGS_TRUE}}
  flags_flagStr_=''
  flags_boolStr_=''
  flags_usName_=`_flags_underscoreName ${flags_name_}`

  flags_default_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_DEFAULT}`
  flags_help_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_HELP}`
  flags_short_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_SHORT}`
  flags_type_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_TYPE}`
  flags_category_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_CATEGORY}`

  flags_help_=$(echo "${flags_help_}"|sed 's/^\ *//g'|tr '\n' ' ')

  if [ ${__FLAGS_GETOPT_VERS} -eq ${__FLAGS_GETOPT_VERS_ENH} ]; then
    # add [no] to long boolean flag names, except the 'help' flags
    [ ${flags_type_} -eq ${__FLAGS_TYPE_BOOLEAN} ] && \
        flags_boolStr_='[no]'
    # long flag name
    flags_flagStr_="${flags_flagStr_}--${flags_boolStr_}${flags_name_}"
  fi
  # short flag name
  [ "${flags_short_}" != "${__FLAGS_NULL}" ] && \
      flags_flagStr_="${flags_flagStr_}, -${flags_short_}"
  # fill with spaces for alignment of help texts
  flags_flagStrLen_=`expr -- "${flags_flagStr_}" : '.*'`
  flags_numSpaces_=`expr -- 6 + "${flags_maxNameLen_}" - "${flags_flagStrLen_}"`
  [ ${flags_numSpaces_} -ge 0 ] || flags_numSpaces_=0
  flags_spaces_=`printf %${flags_numSpaces_}s`
  flags_flagStr_="${flags_flagStr_}${flags_spaces_}"

  case ${flags_type_} in
    ${__FLAGS_TYPE_BOOLEAN})
      if [ ${flags_default_} -eq ${FLAGS_TRUE} ]; then
        flags_defaultStr_='true'
      else
        flags_defaultStr_='false'
      fi
      ;;
    ${__FLAGS_TYPE_STRING}) flags_defaultStr_="'${flags_default_}'" ;;
    *) flags_defaultStr_=${flags_default_} ;;
  esac
  flags_defaultStr_="(default: ${flags_defaultStr_})"

  flags_helpStr_="  ${flags_flagStr_}   ${flags_help_}"
  if [ ${flags_showDefault_} -eq ${FLAGS_TRUE} ]; then
    flags_helpStr_="${flags_helpStr_} ${flags_defaultStr_}"
  fi
  if [ ${flags_showDefault_} -eq ${FLAGS_TRUE} ]; then
    flags_helpStr_="${flags_help_} ${flags_defaultStr_}"
  else
    flags_helpStr_="${flags_help_}"
  fi
  flags_helpStrLen_=`expr -- "${flags_helpStr_}" : '.*'`
  flags_columns_=`_flags_columns`
  # note: the silliness with the x's is purely for ksh93 on Ubuntu 6.06
  # because it doesn't like empty strings when used in this manner.
  flags_emptyStr_="`echo \"x${flags_flagStr_}x\" \
      |awk '{printf "%"length($0)+6"s", ""}'`"
  flags_emptyStrLen_=`expr -- "${flags_emptyStr_}" : '.*'`
  # split long help text on multiple lines
  flags_helpStr_="$(echo "${flags_emptyStr_}${flags_helpStr_}" | fmt -l 0 -${flags_columns_})"
  flags_helpStr_="     ${flags_flagStr_}   ${flags_helpStr_:${flags_emptyStrLen_}}"
  echo "${flags_helpStr_}"

  unset flags_boolStr_ flags_default_ flags_defaultStr_ flags_emptyStr_ flags_emptyStrLen_ \
      flags_flagStr_ flags_help_ flags_helpStr flags_helpStrLen flags_name_ \
      flags_columns_ flags_short_ flags_type_ flags_usName_ flags_flagStrLen_

  return ${FLAGS_TRUE}
}

# Print help of all flags.
#
# This function is used by flags_help() and flags_helpshort().
#
# Args:
#  none
# Returns:
#   integer: success of operation (always returns true)
flags_helpflags()
{
  echo "OPTIONS"
  # get lists of flags belonging to same category and
  # maximum length of long names required for alignment of help
  flags_maxNameLen_=0
  flags_otherFlags_=' '
  for flags_category_ in "${__flags_categoryNames[@]}"; do
    flags_usCategory_=`_flags_underscoreName ${flags_category_}`
    eval "flags_${flags_usCategory_}Flags_=' '"
  done
  for flags_name_ in ${__flags_longNames}; do
    flags_nameStrLen_=`expr -- "${flags_name_}" : '.*'`
    flags_usName_=`_flags_underscoreName ${flags_name_}`
    # length + 4 for boolean flags because of the '[no]' prefix
    flags_type_=`_flags_getFlagInfo "${flags_usName_}" ${__FLAGS_INFO_TYPE}`
    flags_usName_=`_flags_underscoreName ${flags_name_}`
    if [ ${flags_type_} -eq ${__FLAGS_TYPE_BOOLEAN} ]; then
      flags_nameStrLen_=`expr -- "${flags_nameStrLen}" + 4`
    fi
    # update maximum length of flag name
    if [ ${flags_nameStrLen_} -gt ${flags_maxNameLen_} ]; then
      flags_maxNameLen_=${flags_nameStrLen_}
    fi
    # append flag to list for its category
    flags_category_=`_flags_getFlagInfo "${flags_usName_}" ${__FLAGS_INFO_CATEGORY}`
    if [ "${flags_category_}" = "${__FLAGS_NULL}" ]; then
      flags_otherFlags_="${flags_otherFlags_}${flags_name_} "
    else
      flags_usCategory_=`_flags_underscoreName ${flags_category_}`
      eval "flags_${flags_usCategory_}Flags_=\"\${flags_${flags_usCategory_}Flags_}${flags_name_} \""
    fi
  done
  # sort lists
  for flags_category_ in "${__flags_categoryNames[@]}"; do
    flags_usCategory_=`_flags_underscoreName ${flags_category_}`
    eval "flags_${flags_usCategory_}Flags_=\`_flags_sortList \"\${flags_${flags_usCategory_}Flags_}\"\`"
  done
  flags_otherFlags_=`_flags_sortList "${flags_otherFlags_}"`
  # output help of required flags
  if [ -n "${flags_requiredFlags_}" ]; then
    echo "     The required options are as follows:"
    echo
    for flags_name_ in ${flags_requiredFlags_}; do
      flags_helpflag ${flags_name_} ${flags_maxNameLen_} ${FLAGS_FALSE}
    done
    echo
  fi
  # output help of non-required and non-help flags
  for flags_category_ in "${__flags_categoryNames[@]}"; do
    if [ "${flags_category_}" = 'required' -o \
         "${flags_category_}" = 'help' ]; then
      continue
    fi
    flags_usCategory_=`_flags_underscoreName ${flags_category_}`
    eval "flags_names_=\"\${flags_${flags_usCategory_}Flags_}\""
    if [ -n "${flags_names_}" ]; then
      echo "     The ${flags_category_} options are as follows:"
      echo
      for flags_name_ in ${flags_names_}; do
        flags_helpflag ${flags_name_} ${flags_maxNameLen_} ${FLAGS_TRUE}
      done
      echo
    fi
  done
  # output help of remaining non-help flags
  if [ -n "${flags_otherFlags_}" ]; then
    echo "     The available options are as follows:"
    echo
    for flags_name_ in ${flags_otherFlags_}; do
      flags_helpflag ${flags_name_} ${flags_maxNameLen_} ${FLAGS_TRUE}
    done
    echo
  fi
  # output help of help flags
  if [ -n "${flags_helpFlags_}" ]; then
    echo "     The help options are as follows:"
    echo
    for flags_name_ in ${flags_helpFlags_}; do
      flags_helpflag ${flags_name_} ${flags_maxNameLen_} ${FLAGS_FALSE}
    done
    echo
  fi

  # clean up
  for flags_category_ in "${__flags_categoryNames[@]}"; do
    flags_usCategory_=`_flags_underscoreName ${flags_category_}`
    eval "unset flags_${flags_usCategory_}Flags_"
  done
  unset flags_maxNameLen_ flags_name_ flags_nameStrLen_ flags_type_ \
      flags_otherFlags flags_category_ flags_usCategory_
 
  return ${FLAGS_TRUE}
}

# This is effectively a 'usage()' function. It prints a usage information on
# how to use the program and the available flags. Note this function can be
# overridden so other apps can define their own short help output,
# replacing this one, if they want.
#
# Args:
#   none
# Returns:
#   integer: success of operation (always returns true)
flags_helpshort()
{
  # head / usage
  echo
  flags_usage
  echo
  # flags
  flags_helpflags
 
  return ${FLAGS_TRUE}
}

# This is effectively a 'help()' function. It prints a program description together
# with usage information and example command-lines on how to use the program.
# Note this function can be overridden so other apps can define their own help
# output, replacing this one, if they want.
#
# Args:
#  none
# Returns:
#   integer: success of operation (always returns true)
flags_help()
{
  # head / usage
  echo
  flags_usage
  # description
  if [ -n "${HELP_DESCRIPTION:-}" ]; then
    echo
    echo "DESCRIPTION"
    flags_fmtStr_=$(echo "${HELP_DESCRIPTION}"\
        |awk '{printf "%s:NEWLINE:",$0}'\
        |sed 's/^\ *:NEWLINE://g;s/:NEWLINE:\ *$//g;s/:NEWLINE:/:NEWLINE:     /g;s/:NEWLINE:/\\n/g')
    flags_fmtStr_="$(echo -e "     ${flags_fmtStr_}" | fmt -l 0 -$(_flags_columns))"
    echo "${flags_fmtStr_}"
  fi
  # flags
  echo
  flags_helpflags # attention: unsets flags_columns_
  # contact
  if [ -n "${HELP_CONTACT:-}" ]; then
    echo "CONTACT"
    flags_fmtStr_=$(echo "${HELP_CONTACT}"\
        |awk '{printf "%s:NEWLINE:",$0}'\
        |sed 's/^\ *:NEWLINE://g;s/:NEWLINE:$//g;s/:NEWLINE:/:NEWLINE:     /g;s/:NEWLINE:/\\n/g')
    flags_fmtStr_="$(echo "     ${flags_fmtStr_}" | fmt -l 0 -$(_flags_columns))"
    echo "${flags_fmtStr_}"
    echo
  fi
 
  unset flags_fmtStr_

  return ${FLAGS_TRUE}
}

# ----------------------------------------------------------------------------
# XML help
# ----------------------------------------------------------------------------

# This function outputs the help of named flag in XML format
#
# Args:
#   flags_name_: string: long name of flag
#   indentation: integer: (optional) indentation
# Returns:
#   integer: success of operation (always returns true)
flags_helpflagxml()
{
  # get flag attributes
  flags_name_=$1
  flags_indentation_=${2:-0}
  flags_usName_=`_flags_underscoreName ${flags_name_}`

  eval "flags_current_=\${FLAGS_${flags_usName_}}"
  flags_default_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_DEFAULT}`
  flags_help_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_HELP}`
  flags_short_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_SHORT}`
  flags_type_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_TYPE}`
  flags_category_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_CATEGORY}`

  # re-format strings
  flags_help_=$(echo "${flags_help_}"|sed 's/^\ *//g'|tr '\n' ' '|sed 's/^\ *//g;s/\ *$//g')

  [ "${flags_short_}"    = "${__FLAGS_NULL}" ] && flags_short_=''
  [ "${flags_category_}" = "${__FLAGS_NULL}" ] && flags_category_=''

  # convert boolean value
  if [ ${flags_type_} -eq ${__FLAGS_TYPE_BOOLEAN} ]; then
    if [ ${flags_current_} -eq ${FLAGS_TRUE} ]; then
      flags_current_='true'
    else
      flags_current_='false'
    fi
    if [ ${flags_default_} -eq ${FLAGS_TRUE} ]; then
      flags_default_='true'
    else
      flags_default_='false'
    fi
  fi

  # convert type
  case "${flags_type_}" in
    ${__FLAGS_TYPE_BOOLEAN})          flags_type_='bool'; ;;
    ${__FLAGS_TYPE_FLOAT})            flags_type_='double'; ;;
    ${__FLAGS_TYPE_INTEGER})          flags_type_='int'; ;;
    ${__FLAGS_TYPE_UNSIGNED_INTEGER}) flags_type_='uint'; ;;
    ${__FLAGS_TYPE_COUNTER})          flags_type_='int'; ;;
    *)                                flags_type_='string'; ;;
  esac

  # xml-escape values
  flags_short_=`_flags_xmlText "${flags_short_}"`
  flags_category_=`_flags_xmlText "${flags_category_}"`
  flags_help_=`_flags_xmlText "${flags_help_}"`
  flags_current_=`_flags_xmlText "${flags_current_}"`
  flags_default_=`_flags_xmlText "${flags_default_}"`

  # indentation
  flags_emptyStr_=`printf %${flags_indentation_}s`

  # output XML tags
  echo "${flags_emptyStr_}<option id=\"${flags_usName_}\">"
  echo "${flags_emptyStr_}    <name>${flags_name_}</name>"
  echo "${flags_emptyStr_}    <flag>${flags_short_}</flag>"
  echo "${flags_emptyStr_}    <type>${flags_type_}</type>"
  echo "${flags_emptyStr_}    <category>${flags_category_}</category>"
  echo "${flags_emptyStr_}    <help>${flags_help_}</help>"
  echo "${flags_emptyStr_}    <current>${flags_current_}</current>"
  echo "${flags_emptyStr_}    <default>${flags_default_}</default>"
  echo "${flags_emptyStr_}</option>"

  unset flags_current_ flags_default_ flags_name_ flags_usName_ \
      flags_short_ flags_type_ flags_help_ flags_indentation_ \
      flags_emptyStr_
}

# This function outputs the help in XML format.
#
# Args:
#   none
# Returns:
#   integer: success of operation (always returns true)
flags_helpxml()
{
  # get (re-formated) help strings
  flags_executable_=${FLAGS_PARENT:-${0##*/}}
  flags_command_=${HELP_COMMAND:-${flags_executable_}}
  flags_version_=${HELP_VERSION:-'unknown'}
  flags_copyright_=$(echo "${HELP_COPYRIGHT}"\
        |awk '{printf "%s:NEWLINE:",$0}'\
        |sed 's/^\ *:NEWLINE://g;s/:NEWLINE:\ *$//g;s/:NEWLINE:/\\n/g')
  flags_contact_=$(echo "${HELP_CONTACT}"\
        |awk '{printf "%s:NEWLINE:",$0}'\
        |sed 's/^\ *:NEWLINE://g;s/:NEWLINE:$//g;s/:NEWLINE:/\\n/g')
  flags_description_=$(echo "${HELP_DESCRIPTION}"\
        |awk '{printf "%s:NEWLINE:",$0}'\
        |sed 's/^\ *:NEWLINE://g;s/:NEWLINE:\ *$//g;s/:NEWLINE:/\\n/g')

  # xml-escape values
  flags_executable_=`_flags_xmlText "${flags_executable_}"`
  flags_command_=`_flags_xmlText "${flags_command_}"`
  flags_version_=`_flags_xmlText "${flags_version_}"`
  flags_copyright_=`_flags_xmlText "${flags_copyright_}"`
  flags_contact_=`_flags_xmlText "${flags_contact_}"`
  flags_description_=`_flags_xmlText "${flags_description_}"`

  # output XML tags
  echo "<?xml version=\"1.0\"?>"
  echo "<executable id=\"${flags_command_}\">"
  echo "    <name>${flags_executable_}</name>"
  echo "    <version>${flags_version_}</version>"
  echo "    <copyright>${flags_copyright_}</copyright>"
  echo "    <contact>${flags_contact_}</contact>"
  echo "    <description>${flags_description_}</description>"
  echo "    <options>"
  for flags_name_ in ${__flags_longNames}; do
    flags_helpflagxml ${flags_name_} 8
  done
  echo "    </options>"
  echo "</executable>"

  # clean up
  unset flags_executable_ flags_command_ flags_version_ \
      flags_name_ flags_description_ flags_copyright_ flags_contact_

  return ${FLAGS_TRUE}
}

# ----------------------------------------------------------------------------
# man page
# ----------------------------------------------------------------------------

# Prints NAME section of man page.
flags_helpman_name()
{
  flags_command_=${HELP_COMMAND:-${0##*/}}
  flags_command_=`_flags_manText "${flags_command_}"`

  echo ".SH NAME"
  # use first sentence of description as brief description similar to Doxygen
  if [ -n "${HELP_DESCRIPTION}" ]; then
    flags_brief_=${HELP_DESCRIPTION%%.*}
    flags_brief_="$(echo "${flags_brief_}"|sed 's/^\ *//g;s/\ *$//g'|tr '\n' ' ')"
    flags_brief_="${flags_command_} -- ${flags_brief_}"
    flags_columns_=`_flags_columns`
    flags_columns_=`expr -- "${flags_columns_}" - 24`
    [ ${flags_columns_} -lt 80 ] && flags_columns_=80
    if [ `expr -- "${flags_brief_}" : '.*'` -gt ${flags_columns_} ]; then
      flags_brief_="${flags_brief_:0:${flags_columns_}}"
      flags_brief_="${flags_brief_% *}..."
    fi
    flags_brief_=`_flags_manText "${flags_brief_}"`
    echo "${flags_brief_}"
  else
    echo "${flags_command_}"
  fi

  unset flags_command_ flags_brief_ flags_columns_

  return ${FLAGS_TRUE}
}

# Prints SYNOPSIS section of man page.
flags_helpman_synopsis()
{
  flags_executable_="${FLAGS_PARENT:-${0##*/}}"

  echo ".SH SYNOPSIS"
  echo "\fB${flags_executable_}\fR"

  flags_requiredFlags_=' '
  flags_optionalFlags_=' '
  for flags_name_ in ${__flags_longNames}; do
    flags_usName_=`_flags_underscoreName ${flags_name_}`
    flags_category_=`_flags_getFlagInfo "${flags_usName_}" ${__FLAGS_INFO_CATEGORY}`
    if [ "${flags_category_}" = 'required' ]; then
      flags_requiredFlags_="${flags_requiredFlags_}${flags_name_} "
    elif [ "${flags_category_}" != 'help' ]; then
      flags_optionalFlags_="${flags_optionalFlags_}${flags_name_} "
    fi
  done

  flags_requiredFlags_=`_flags_sortList "${flags_requiredFlags_}"`
  flags_optionalFlags_=`_flags_sortList "${flags_optionalFlags_}"`

  if [ -n "${flags_optionalFlags_}" ]; then
    for flags_name_ in ${flags_optionalFlags_}; do
      flags_usName_=`_flags_underscoreName ${flags_name_}`
      flags_type_=`_flags_getFlagInfo "${flags_usName_}" ${__FLAGS_INFO_TYPE}`
      case ${flags_type_} in
        ${__FLAGS_TYPE_BOOLEAN})
          echo "[\fB--[no]${flags_name_}\fR]"
          ;;

        ${__FLAGS_TYPE_FLOAT})
          echo "[\fB--${flags_name_}=\fR\fIfloat\fR]"
          ;;

        ${__FLAGS_TYPE_INTEGER})
          echo "[\fB--${flags_name_}=\fR\fIint\fR]"
          ;;

        ${__FLAGS_TYPE_UNSIGNED_INTEGER})
          echo "[\fB--${flags_name_}\fR=\fIuint\fR]"
          ;;

        ${__FLAGS_TYPE_STRING})
          echo "[\fB--${flags_name_}\fR=\fIstring\fR]"
          ;;

        ${__FLAGS_TYPE_COUNTER})
          echo "[\fB--${flags_name_}\fR...]"
          ;;

        *)
          echo "[\fB--${flags_name_}\fR=\fIvalue\fR]"
          ;;
      esac
    done
  fi
  if [ -n "${flags_requiredFlags_}" ]; then
    for flags_name_ in ${flags_requiredFlags_}; do
      flags_usName_=`_flags_underscoreName ${flags_name_}`
      flags_type_=`_flags_getFlagInfo "${flags_usName_}" ${__FLAGS_INFO_TYPE}`
      case ${flags_type_} in
        ${__FLAGS_TYPE_BOOLEAN})
          echo "\fB--[no]${flags_name_}\fR"
          ;;

        ${__FLAGS_TYPE_FLOAT})
          echo "\fB--${flags_name_}=\fR\fIfloat\fR"
          ;;

        ${__FLAGS_TYPE_INTEGER})
          echo "\fB--${flags_name_}=\fR\fIint\fR"
          ;;

        ${__FLAGS_TYPE_UNSIGNED_INTEGER})
          echo "\fB--${flags_name_}\fR=\fIuint\fR"
          ;;

        ${__FLAGS_TYPE_STRING})
          echo "\fB--${flags_name_}\fR=\fIstring\fR"
          ;;

        ${__FLAGS_TYPE_COUNTER})
          echo "\fB--${flags_name_}\fR..."
          ;;

        *)
          echo "\fB--${flags_name_}\fR=\fIvalue\fR"
          ;;
      esac
    done
  fi
  echo "[args]"

  unset flags_executable_ flags_name_ flags_usName_ flags_type_ \
      flags_optionalFlags_ flags_requiredFlags_

  return ${FLAGS_TRUE}
}

# Prints DESCRIPTION section of man page.
flags_helpman_description()
{
  if [ -n "${HELP_DESCRIPTION}" ]; then
    echo ".SH DESCRIPTION"
    flags_description_="${HELP_DESCRIPTION:-'No description available.'}"
    flags_description_=`_flags_manText "${flags_description_}"`
    echo "${flags_description_}"

    unset flags_description_
  fi
}

# Prints OPTIONS section entry of man page of named flag.
flags_helpman_flag()
{
  flags_name_=$1
  flags_showDefault_=${2:-${FLAGS_TRUE}}
  flags_flagStr_=''
  flags_boolStr_=''
  flags_usName_=`_flags_underscoreName ${flags_name_}`

  flags_default_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_DEFAULT}`
  flags_help_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_HELP}`
  flags_short_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_SHORT}`
  flags_type_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_TYPE}`
  flags_category_=`_flags_getFlagInfo \
      "${flags_usName_}" ${__FLAGS_INFO_CATEGORY}`

  flags_help_=$(echo "${flags_help_}"|sed 's/^\ *//g'|tr '\n' ' ')

  if [ ${__FLAGS_GETOPT_VERS} -eq ${__FLAGS_GETOPT_VERS_ENH} ]; then
    # add [no] to long boolean flag names, except the 'help' flags
    [ ${flags_type_} -eq ${__FLAGS_TYPE_BOOLEAN} ] && \
        flags_boolStr_='[no]'
    # long flag name
    flags_flagStr_="\fB${flags_flagStr_}--${flags_boolStr_}${flags_name_}"
  fi
  # short flag name
  [ "${flags_short_}" != "${__FLAGS_NULL}" ] && \
      flags_flagStr_="${flags_flagStr_}, -${flags_short_}"
  flags_flagStr_="${flags_flagStr_}\fR"
  # default value
  case ${flags_type_} in
    ${__FLAGS_TYPE_BOOLEAN})
      if [ ${flags_default_} -eq ${FLAGS_TRUE} ]; then
        flags_defaultStr_='true'
      else
        flags_defaultStr_='false'
      fi
      ;;
    ${__FLAGS_TYPE_STRING}) flags_defaultStr_="'${flags_default_}'" ;;
    *) flags_defaultStr_=${flags_default_} ;;
  esac

  if [ ${flags_type_} -ne ${__FLAGS_TYPE_BOOLEAN} -a \
       ${flags_type_} -ne ${__FLAGS_TYPE_COUNTER} ]; then
    case "${flags_type_}" in
      ${__FLAGS_TYPE_BOOLEAN})          flags_typeStr_='bool'; ;;
      ${__FLAGS_TYPE_FLOAT})            flags_typeStr_='double'; ;;
      ${__FLAGS_TYPE_INTEGER})          flags_typeStr_='int'; ;;
      ${__FLAGS_TYPE_UNSIGNED_INTEGER}) flags_typeStr_='uint'; ;;
      ${__FLAGS_TYPE_COUNTER})          flags_typeStr_='count'; ;;
      *)                                flags_typeStr_='string'; ;;
    esac
    flags_flagStr_="${flags_flagStr_} \fI${flags_typeStr_}\fR"
  fi

  if [ ${flags_showDefault_} -eq ${FLAGS_TRUE} ]; then
    flags_defaultStr_=" (default:\ ${flags_defaultStr_//\ /\\ })"
  else
    flags_defaultStr_=''
  fi

  echo ".TP 8"
  echo "${flags_flagStr_}"
  echo "${flags_help_}${flags_defaultStr_}"

  unset flags_boolStr_ flags_default_ flags_defaultStr_ flags_emptyStr_ flags_emptyStrLen_ \
      flags_flagStr_ flags_help_ flags_helpStr flags_helpStrLen flags_name_ \
      flags_columns_ flags_short_ flags_type_ flags_usName_ flags_flagStrLen_

  return ${FLAGS_TRUE}
}

# Prints OPTIONS section of man page.
flags_helpman_flags()
{
  echo ".SH OPTIONS"
  # get lists of flags belonging to same category
  flags_otherFlags_=' '
  for flags_category_ in "${__flags_categoryNames[@]}"; do
    flags_usCategory_=`_flags_underscoreName ${flags_category_}`
    eval "flags_${flags_usCategory_}Flags_=' '"
  done
  for flags_name_ in ${__flags_longNames}; do
    flags_nameStrLen_=`expr -- "${flags_name_}" : '.*'`
    flags_usName_=`_flags_underscoreName ${flags_name_}`
    flags_category_=`_flags_getFlagInfo "${flags_usName_}" ${__FLAGS_INFO_CATEGORY}`
    if [ "${flags_category_}" = "${__FLAGS_NULL}" ]; then
      flags_otherFlags_="${flags_otherFlags_}${flags_name_} "
    else
      flags_usCategory_=`_flags_underscoreName ${flags_category_}`
      eval "flags_${flags_usCategory_}Flags_=\"\${flags_${flags_usCategory_}Flags_}${flags_name_} \""
    fi
  done
  # sort lists
  for flags_category_ in "${__flags_categoryNames[@]}"; do
    flags_usCategory_=`_flags_underscoreName ${flags_category_}`
    eval "flags_${flags_usCategory_}Flags_=\`_flags_sortList \"\${flags_${flags_usCategory_}Flags_}\"\`"
  done
  flags_otherFlags_=`_flags_sortList "${flags_otherFlags_}"`
  # output help of required flags
  if [ -n "${flags_requiredFlags_}" ]; then
    echo ".P"
    echo "\fBThe required options are as follows:\fR"
    for flags_name_ in ${flags_requiredFlags_}; do
      flags_helpman_flag ${flags_name_} ${FLAGS_FALSE}
    done
  fi
  # output help of non-required and non-help flags
  for flags_category_ in "${__flags_categoryNames[@]}"; do
    if [ "${flags_category_}" = 'required' -o \
         "${flags_category_}" = 'help' ]; then
      continue
    fi
    flags_usCategory_=`_flags_underscoreName ${flags_category_}`
    eval "flags_names_=\"\${flags_${flags_usCategory_}Flags_}\""
    if [ -n "${flags_names_}" ]; then
      echo ".P"
      echo "\fBThe ${flags_category_} options are as follows:\fR"
      for flags_name_ in ${flags_names_}; do
        flags_helpman_flag ${flags_name_}
      done
    fi
  done
  # output help of remaining non-help flags
  if [ -n "${flags_otherFlags_}" ]; then
    echo ".P"
    echo "\fBThe available options are as follows:\fR"
    for flags_name_ in ${flags_otherFlags_}; do
      flags_helpman_flag ${flags_name_}
    done
  fi
  # output help of help flags
  if [ -n "${flags_helpFlags_}" ]; then
    echo ".P"
    echo "\fBThe help options are as follows:\fR"
    for flags_name_ in ${flags_helpFlags_}; do
      flags_helpman_flag ${flags_name_} ${FLAGS_FALSE}
    done
  fi

  # clean up
  for flags_category_ in "${__flags_categoryNames[@]}"; do
    flags_usCategory_=`_flags_underscoreName ${flags_category_}`
    eval "unset flags_${flags_usCategory_}Flags_"
  done
  unset flags_maxNameLen_ flags_name_ flags_nameStrLen_ flags_type_ \
      flags_otherFlags flags_category_ flags_usCategory_
}

# Prints COPYRIGHT section of man page.
flags_helpman_copyright()
{
  if [ -n "${HELP_COPYRIGHT}" ]; then
    echo ".SH COPYRIGHT"
    flags_copyright_="${HELP_COPYRIGHT}"
    flags_copyright_=`echo "${flags_copyright_}"|awk '{printf "%s\n.br\n",$0}'`
    flags_copyright_=`_flags_manText "${flags_copyright_}"`
    echo "${flags_copyright_}"

    unset flags_copyright_
  fi
}

# Prints CONTACT section of man page.
flags_helpman_contact()
{
  if [ -n "${HELP_CONTACT}" ]; then
    echo ".SH CONTACT"
    flags_contact_="${HELP_CONTACT}"
    flags_contact_=`_flags_manText "${flags_contact_}"`
    echo "${flags_contact_}"

    unset flags_contact_
  fi
}

# This function outputs the help in man page format.
#
# Args:
#   none
# Returns:
#   integer: success of operation (always returns true)
flags_helpman()
{
  flags_command_=${FLAGS_PARENT:-${0##*/}}
  flags_command_=`_flags_manText "${flags_command_}"`

  echo ".TH \"${flags_command_}\" 1 `date '+%e\ %B\ %G'`"
  flags_helpman_name
  flags_helpman_synopsis
  flags_helpman_description
  flags_helpman_flags
  flags_helpman_copyright
  flags_helpman_contact

  unset flags_command_

  return ${FLAGS_TRUE}
}

# ----------------------------------------------------------------------------
# version information
# ----------------------------------------------------------------------------

# This function outputs the version and copyright.
#
# Args:
#   none
# Returns:
#   integer: success of operation (always returns true)
flags_version()
{
  flags_command_=${HELP_COMMAND:-$0##*/}
  flags_version_=${HELP_VERSION:-'unknown'}
  echo "${flags_command_} version ${flags_version_}"
  if [ -n "${HELP_COPYRIGHT}" ]; then
    flags_copyright_=$(echo "${HELP_COPYRIGHT}"\
        |awk '{printf "%s:NEWLINE:",$0}'\
        |sed 's/^\ *:NEWLINE://g;s/:NEWLINE:\ *$//g;s/:NEWLINE:/\\n/g')
    echo -e "${flags_copyright_}"
  fi
  unset flags_command_ flags_version_ flags_copyright_
}

# ----------------------------------------------------------------------------
# reset
# ----------------------------------------------------------------------------

# Reset shflags back to an uninitialized state.
#
# Args:
#   none
# Returns:
#   nothing
flags_reset()
{
  for flags_name_ in ${__flags_longNames}; do
    flags_usName_=`_flags_underscoreName ${flags_name_}`
    flags_strToEval_="unset FLAGS_${flags_usName_}"
    for flags_type_ in \
        ${__FLAGS_INFO_DEFAULT} \
        ${__FLAGS_INFO_HELP} \
        ${__FLAGS_INFO_SHORT} \
        ${__FLAGS_INFO_TYPE} \
        ${__FLAGS_INFO_CATEGORY}
    do
      flags_strToEval_=\
"${flags_strToEval_} __flags_${flags_usName_}_${flags_type_}"
    done
    eval ${flags_strToEval_}
  done

  # reset internal variables
  __flags_boolNames=' '
  __flags_longNames=' '
  __flags_shortNames=' '
  __flags_definedNames=' '
  __flags_categoryNames=' '

  unset flags_name_ flags_type_ flags_strToEval_ flags_usName_
}