# Copyright © Jim Avera 2012-2022.  This document contains code snippets
# from perl5db.pl and Data::Dumper as noted in adjacent comments, and
# those extracts remain subject to the licenses of their respective sources.
# Other portions have been released into the Public Domain in accordance with
# Creative Commons CC0 (http://creativecommons.org/publicdomain/zero/1.0/)
use strict; use warnings FATAL => 'all'; use 5.012;
use feature qw(switch state);

use utf8;
# This file contains UTF-8 characters in debug-output strings (e.g. « and »).
# But to see them correctly on a non-Latin1 terminal (e.g. utf-8), your
# program has to say
#   use open ':std' => ':locale';
# or otherwise set the STDERR encoding to match what your terminal expects
# (Perl assumes Latin-1 by default).

package Vis;
# See below for $VERSION and POD documentation

# *** The following must appear before anything is declared which might
# *** alias a user-provided thing referenced in svis/dvis strings we eval

package DB;

# eval a string in the user's context and return the result.  The nearest
# non-DB frame must be the original user's call; this is accomplished by
# using "goto &_Interpolate" in the entry-point sub to substitute a call
# directly into package DB.  
# The following globals must be pre-set:
#   @Vis::saved = ($@, $!, $^E, $,, $/, $\, $^W)
#   $Vis:evalarg 
sub DB_Vis_EvalInner {   # Many ideas here taken from perl5db.pl
  warn "### DB_Vis_EvalInner Entry evalarg='$Vis::evalarg' ----------------------------------\n";

  # We can not use lexicals because they could mask user vars
  
  ($Vis::pkg) = (caller(0))[0];  # package containig user's call

  # Get @_ values from the closest non-DB caller which has arguments.
  # This will be the closest caller unless that sub as called 
  # using "&subname;".  N.B. caller() leaves the args in @DB::args
  # FIXME: change main:: to Vis:: ...
  for ($main::dist = 0; (caller($main::dist)//"") eq "DB"; $main::dist++) {}
  while() {
    $main::dist++;
    my ($pkg, $hasargs) = (caller($main::dist))[0,4];
    if (! defined $pkg){
      @DB::args = ('<@_ is not defined in the outer block>');
      last
    }
    last if $hasargs;
  }
  local *_ = \@DB::args;

  # At this point, nothing is in scope except the name of this sub
  # and the simulated @_.
  {
    #FIXME: If 'no strict refs' is not needed, simplify be rming {...}
    #no strict 'refs';
Carp::confess("BUG") unless @Vis::saved;
    ($!, $^E, $,, $/, $\, $^W) = @Vis::saved[1..6];
    # LHS of assignment must be inside eval to catch die from tie handlers
    $Vis::evalstr = "package $Vis::pkg;"
                         .' $@ = $Vis::saved[0];'
                         .' { local @Vis::saved;'
                         .'   @Vis::result = '.$Vis::evalarg.';'
                         .' } '
                         .' $Vis::saved[0] = $@;'  # might be set via tie
                         ;
    eval $Vis::evalstr;
  };
  $Vis::busy--;

  # Because of tied variables, we may have just executed user code!
  # Re-save the possibly-modified punctuation variables and reset them to
  # sane values to ensure that our code can function.
  #
  # However $@ here is from our eval, not the result of any tie handlers.
  # $@ was saved to $saved[0] inside the eval, and we want to keep that value.
  # The following "local" statement causes that value to be preserved over
  # the call to &SaveAndResetPunct
  { local $Vis::save_stack[0]->[0]; &Vis::Resavepunct; }

  if (my $exmsg = $@) {
    my ($pkg, $fname, $lno) = (caller($main::dist - 1));
    $exmsg =~ s/ at \(eval \d+\) line \d+[^\n]*//sg;
    Carp::confess("${Vis::funcname}: Error interpolating '$Vis::evalarg' at $fname line $lno:\n$exmsg\n");
  }

  my @res = @Vis::result;

  Vis::oops() if @res != 1; # we never generate array results
  $res[0]
}# DB_Vis_EvalInner

sub DB_Vis_Eval($$) {
  my ($label_for_errmsg, $evalarg) = @_;
  # The inner-most function can not have any lexicals, so pass in globals
  $Vis::funcname = $label_for_errmsg;
  $Vis::evalarg = $evalarg;
  state $busy;
  Carp::confess("Recursive svis/dvis not supported")
    if $busy++;
  my $r = &DB::DB_Vis_EvalInner;
  $busy--;
  $r
}

sub DB::DB_Vis_Interpolate {
  (my $self, local $_, my $s_or_d) = @_;
  &Vis::SaveAndResetPunct;

  # cf man perldata
  my $userident_re = qr/ (?: (?=\p{Word})\p{XID_Start} | _ )
                         (?: (?=\p{Word})\p{XID_Continue}  )* /x;
  
  my $varname_re = qr/ ${userident_re} | \^[A-Z] | [0-9]+
                                       | [-+!().,\/:<>?\[\]\^\\]
                                       /x;
  
  my $varname_or_refexpr_re = qr/ ${varname_re} | ${Vis::curlies_re} /x;

  return "<undef arg>" 
    if ! defined;
  if (/\b((?:ARRAY|HASH)\(0x[a-fA-F0-9]+\))/) {
    state $warned=0;
    Carp::carp("Warning: String passed to ${s_or_d}vis may have been interpolated by Perl\n(use 'single quotes' to avoid this)\n") unless $warned++;
  }
  my $debug = $self->Debug;
  my $useqq = $self->Useqq;
  my $q = $useqq ? "" : "q";
  my $funcname = $s_or_d . "vis" .$q;
  my sub __check_notmissed($$) {
    my ($plainstuff, $posn) = @_;
    local $_ = $_;
    $plainstuff !~ /(?<!\\)([\$\@\%])/
      or Carp::confess("\n***Vis bug: Unparsed '$1' at offset ",u($posn),
                       " ->",substr($_,$posn//0) );
  }
  my $result = "";
  while (
    /\G (.*?)
        (
         # $#arrayvar $#$$...refvarname $#{aref expr} $#$$...{ref2ref expr}
         #
         (?: \$\#\$*+\K ${varname_or_refexpr_re} )
         |
         # $scalarvar $$$...refvarname ${sref expr} $$$...{ref2ref expr}
         #  followed by [] {} ->[] ->{} ->method() ... «zero or more»
         #
         (?:
           \$++\K ${varname_or_refexpr_re}
           (?:
             (?: ->\K(?: ${$Vis::curliesorsquares_re} | ${userident_re}${Vis::parens_re}? ))
             |
             ${$Vis::curliesorsquares_re}
           )*
         )
         |
         # @arrayvar @$$...varname @{aref expr} @$$...{ref2ref expr}
         #  followed by [] {} «zero or one»
         #
         (?: \@\$*+\K ${varname_or_refexpr_re} ${$Vis::curliesorsquares_re}? )
         |
         # %hash %$hrefvar %{href expr} %$$...sref2hrefvar «no follow-ons»
         (?: \%\$*+\K ${varname_or_refexpr_re} )
        )
    /xsgc) {
    $result .= $1;
    __check_notmissed($1, pos()-length($2)-length($1));
    if ($2) {
      my $sigl = substr($2,0,1);
      if ($s_or_d eq 'd') {
        local $_ = $2;
        # Show "foo=<value>" for "$foo" but otherwise use entire expr as label
        $result .= (/^\$(${userident_re})\z/ ? $1 : "\\".$2)."=";
      }
      # Reduce indent before first wrap to account for stuff alrady there
      my $used = length($result) - rindex($result,"\n") - 1;
      local $Vis::Maxwidth = $Vis::Maxwidth;
      $Vis::Maxwidth -= $used 
        if $used < $Vis::Maxwidth;
      say "${s_or_d}vis: used=$used, temp reduced Maxwidth=$Vis::Maxwidth";

      if ($sigl eq '$') {
        $result .= Vis::vis( DB::DB_Vis_Eval($funcname, $2) );
      }
      elsif ($sigl eq '@') {
        # FIXME verify that multi-value eval results work
        $result .= Vis::avis( DB::DB_Vis_Eval($funcname, $2) );
      }
      elsif ($sigl eq '%') {
        $result .= Vis::hvis( DB::DB_Vis_Eval($funcname, $2) );
      }
      else { Carp::confess("BUG:sigl='$sigl'") }
    }
  }
  if (!defined(pos) || pos() < length($_)) {
    my $leftover = substr($_,pos()//0);
    #say "LEFTOVER: «$leftover»";
    __check_notmissed($leftover,pos);
    $result .= $leftover;
  }

  &Vis::RestorePunct;
  $result
}#DB::DB_Vis_Interpolate


package Vis;

use version 0.77; our $VERSION = version->declare(sprintf "v%s", q$Revision: 1.159 $ =~ /(\d[.\d]+)/);

use Exporter;
use Carp;
use POSIX qw(INT_MAX);
use Encode ();
use Scalar::Util qw(blessed reftype refaddr looks_like_number);
use List::Util qw(min max first any);
use Regexp::Common qw/RE_balanced/;
use overload ();

use Terminalsize qw(get_terminal_columns);

require Data::Dumper;

use Exporter 'import';
our @EXPORT    = qw(vis  avis  lvis  svis  dvis  hvis  hlvis
                    visq avisq lvisq svisq dvisq hvisq hlvisq
                    u qsh forceqsh qshpath);

our @EXPORT_OK = qw($Maxwidth $MaxStringwidth $Truncsuffix $Debug
                    $Stringify $Usehex
                    $Useqq $Quotekeys $Sortkeys $Terse $Indent $Sparseseen);

our @ISA       = ('Data::Dumper'); # see comments at new()

# Used by non-oo functions, and initial settings by new()
our ($Maxwidth, $MaxStringwidth, $Truncsuffix, $Debug, $Stringify, $Usehex,
     $Useqq, $Quotekeys, $Sortkeys, $Terse, $Indent, $Sparseseen);

$Debug          = 0            unless defined $Debug;
$MaxStringwidth = 0            unless defined $MaxStringwidth;
$Maxwidth       = undef        unless defined $Maxwidth; # undef to auto-detect
$Truncsuffix    = "..."        unless defined $Truncsuffix;
$Stringify      = 1            unless defined $Stringify;
$Usehex         = 1            unless defined $Usehex; # for binary octets

# The following Vis defaults override Data::Dumper defaults
$Useqq          = 1            unless defined $Useqq;
$Quotekeys      = 0            unless defined $Quotekeys;
$Sortkeys       = \&__sortkeys unless defined $Sortkeys;
$Terse          = 1            unless defined $Terse;
$Indent         = 1            unless defined $Indent;
$Sparseseen     = 1            unless defined $Sparseseen;

sub Debug {
  my($s, $v) = @_;
  @_ >= 2 ? (($s->{VisDebug} = $v), return $s) : $s->{VisDebug};
}
sub MaxStringwidth {
  my($s, $v) = @_;
  @_ >= 2 ? (($s->{MaxStringwidth} = $v), return $s) : $s->{MaxStringwidth};
}
sub Maxwidth {
  my($s, $v) = @_;
  @_ >= 2 ? (($s->{Maxwidth} = $v), return $s) : $s->{Maxwidth};
}
sub Truncsuffix {
  my($s, $v) = @_;
  @_ >= 2 ? (($s->{Truncsuffix} = $v), return $s) : $s->{Truncsuffix};
}
sub Stringify {
  my($s, $v) = @_;
  @_ >= 2 ? (($s->{Stringify} = $v), return $s) : $s->{Stringify};
}
sub Usehex {
  my($s, $v) = @_;
  @_ >= 2 ? (($s->{Usehex} = $v), return $s) : $s->{Usehex};
}
sub VisType {
  my($s, $v) = @_;
  @_ >= 2 ? (($s->{VisType} = $v), return $s) : $s->{VisType};
}

sub debugvis(_) {  # for our internal debug messages
  my $s = Data::Dumper->new([shift])->Useqq(1)->Terse(1)->Indent(0)->Maxdepth(2)->Dump;
  chomp $s;
  $s
}
sub debugavis(@) { "(" . join(", ", map{debugvis} @_) . ")" }

sub oops(@) { @_ = ("\noops:",@_,"\n  "); goto &Carp::confess }

############### Functional (non-oo) APIs #################
sub u(_) { $_[0] // "undef" }
sub forceqsh(_) {
  # Unlike Perl, the bourne shell does not recognize backslash escapes
  # inside '...', but quoting must be interrupted, e.g. 'foo\''bar'
  local $_ = shift;
  return "undef" unless defined;
  $_ = Vis::vis($_) if ref;
  # Prefer "double quoted" if no shell escapes would be needed
  if (/["\$`!\\\x{00}-\x{1F}\x{7F}]/) {
    s/'/'\\''/g; # foo'bar => foo'\''bar
    return "'${_}'";
  } else {
    return "\"${_}\"";
  }
}
sub qsh(_) {
  local $_ = shift;
  defined && !/[^-=\w_\/:\.,]/ && $_ ne "" && !ref ? $_ : forceqsh
}

sub qshpath(_) {  # like qsh but does not quote initial ~ or ~username
  local $_ = shift;
  return qsh if !defined or ref;
  my ($tilde_prefix, $rest) = /^( (?:\~[^\/\\]*[\/\\]?+)? )(.*)/xs or die;
  $rest eq "" ? $tilde_prefix : $tilde_prefix.qsh($rest)
}

########### FUNCTIONAL/OO APIs #############
sub _getobj {
  (blessed($_[0]) && $_[0]->isa(__PACKAGE__) ? shift : __PACKAGE__->new())
}
sub _getobj_scalar { &_getobj->Values([$_[0]]) }
sub _getobj_array  { &_getobj->Values([\@_])   } #->Values([[@_]])
sub _getobj_hash {
  my $o = &_getobj;
  (scalar(@_) % 2)==0 or croak "Uneven number args for hash key => val pairs";
  $o ->Values([{@_}])
}

# These can be called as *FUNCTIONS* or as *METHODS* of an
# already-created Vis object.
sub vis(_)    { &_getobj_scalar->VisType('s' )->Dump; }
sub visq(_)   { &_getobj_scalar->VisType('s' )->Useqq(0)->Dump; }
sub avis(@)   { &_getobj_array ->VisType('a' )->Dump; }
sub avisq(@)  { &_getobj_array ->VisType('a' )->Useqq(0)->Dump; }
sub lvis(@)   { &_getobj_array ->VisType('l' )->Dump; }
sub lvisq(@)  { &_getobj_array ->VisType('l' )->Useqq(0)->Dump; }
sub hvis(@)   { &_getobj_hash  ->VisType('h' )->Dump; }
sub hvisq(@)  { &_getobj_hash  ->VisType('h' )->Useqq(0)->Dump; }
sub hlvis(@)  { &_getobj_hash  ->VisType('hl')->Dump; }
sub hlvisq(@) { &_getobj_hash  ->VisType('hl')->Useqq(0)->Dump; }

# Trampolines which replace the call frame with a call directly to the
# interpolation code which uses package DB to access the user's context.
sub svis(_) { @_=(&_getobj,           shift, 's');goto &DB::DB_Vis_Interpolate }
sub svisq(_){ @_=(&_getobj->Useqq(0), shift, 's');goto &DB::DB_Vis_Interpolate }
sub dvis(_) { @_=(&_getobj,           shift, 'd');goto &DB::DB_Vis_Interpolate }
sub dvisq(_){ @_=(&_getobj->Useqq(0), shift, 'd');goto &DB::DB_Vis_Interpolate }

# Our new() takes no parameters and returns a default-initialized object,
# on which option-setting methods may be called and finally "vis", "avis", etc.
# as a method to produce the output (those routines can also be called as
# functions, in which case they create a new object internally).
#
# We do have a Dump() method and theoretically users could call it
# directly on a Vis object if they first call Values() to set the datum
# and VisType() to set the format style.  This is not documented.
#
# An earlier version of this package was designed to be a true drop-in
# replacement for Data::Dumper will all the same APIs (mostly by inheritance)
# including Data::Dumper's new([values],[names]) interface.
# New features were exposed via special constructors (snew, anew, hnew, etc.)
# and vis, avis, etc. were just functions which called the approprieate
# special constructor.  With unpleasantly lengthy documentation.
#
# The current design is not API compatible with Data::Dumper, but still
# derives from Data::Dumper and users could call obscure Data::Dumper
# config options to affect our output.  This is not supported or documented.
#
# Arguably deriving from Data::Dumper no longer makes sense and we should
# just use it internally ("has a" relationship).  But that is a project
# for another day.
sub new {
  croak "No args allowed for Vis::new" if @_ > 1;
  my ($class) = @_;
  (bless $class->SUPER::new([],[]), $class)->_config_defaults()
}

############# only internals follow ############
sub _config_defaults {
  my $self = shift;

  if (! defined $Maxwidth) {
    local *_;
    # perl bug: Localizing *_ does not deal with the special filehandle "_"
    #  see https://github.com/Perl/perl5/issues/19142
    $Maxwidth = get_terminal_columns(debug => $Debug)//80;
  }

  $self
    ->Quotekeys($Quotekeys)
    ->Sortkeys($Sortkeys)
    ->Terse($Terse)
    ->Indent($Indent)
    ->Debug($Debug)
    ->Stringify($Stringify)
    ->Usehex($Usehex)
    ->Useqq($Useqq)
    ->Sparseseen($Sparseseen)
    ->Maxwidth($Maxwidth)
    ->MaxStringwidth($MaxStringwidth)
    ->Truncsuffix($Truncsuffix)
}

my $magic_num_prefix = "NUM:".\&new;        # "NUM:CODE(0x.......)"
my $magic_numstr_prefix = "NUMSTR:".\&new;

sub __walk_worker($$$$$) {
  my (undef, $detection_pass, $stringify, $maxstringwidth, $truncsuf) = @_;
  return 1
    unless defined $_[0];
  # Truncate over-length strings
  if ($maxstringwidth) {
    if (ref($_[0]) eq "") { # a scalar
      my $maxwid = $maxstringwidth + length($truncsuf);
      if (!show_as_number($_[0])
          && length($_[0]) > $maxstringwidth + length($truncsuf)) {
        return \undef if $detection_pass;
        $_[0] = substr($_[0],0,$maxstringwidth).$truncsuf;
      }
    }
  }
  if (my $class = blessed($_[0])) {
    # Strinify objects which have the stringification operator
    if (overload::Method($class,'""')) { # implements operator stringify
      # FIXME: use List::Util::any
      my $shouldwe;
      foreach my $mod (@$stringify) {
        # Stringify may be class name, a Regexp matching class name,
        # or the number 1 (to enable any class)
        $shouldwe=1, last if
          ref($mod) eq "Regexp"
            ? $class =~ /$mod/
            : ($class eq $mod || $mod eq "1")
      }
      if ($shouldwe) {
        return \undef if $detection_pass;  # halt immediately
        # Make the change.  We are on a 2nd pass on a cloned copy
        my $prefix = show_as_number($_[0]) ? $magic_num_prefix : "";
        $_[0] = "${prefix}($class)".$_[0];  # *calls stringify operator*
      }
    }
  }
  # Prepend a "magic prefix" to items which Data::Dumper is likely
  # to represent wrongly or anyway not how we want.  The prefix will
  # be removed from the result later.
  #
  # 1. Scalars is set to a string like "6" will come out as a number
  #    instead of string (except with Useqq(0) and Useperl(0)).
  #    This is a bug.
  # 2. All floating point values come out as "strings" to avoid
  #    some cross-platform issues.  We don't want that.
  if (!reftype($_[0]) && looks_like_number($_[0])) {
    return \undef if $detection_pass;  # halt immediately
    my $prefix = show_as_number($_[0])
                   ? $magic_num_prefix : $magic_numstr_prefix;
    $_[0] = $prefix.$_[0];
  }
  1
}

sub Dump {
  my $self = $_[0];
  &SaveAndResetPunct;
  local $_;
  if (! ref $self) { # ala Data::Dumper
    $self = $self->new(@_[1..$#_]);
  } else {
    croak "extraneous args" if @_ != 1;
  }

  my ($debug, $maxstringwidth, $stringify)
    = @$self{qw/VisDebug MaxStringwidth Stringify/};

  #------------------------------------------------------
  # Do desired substitutions in the data (cloning first)
  #------------------------------------------------------
  if ($stringify || $maxstringwidth) {
    $stringify = [ $stringify ] unless ref($stringify) eq 'ARRAY';
    $maxstringwidth //= 0;
    my $truncsuf = $self->{Truncsuffix};
    my $r = $self->_Visit_Values(
      sub{ __walk_worker(shift,1,$stringify,$maxstringwidth,$truncsuf) } );
    if (ref $r) {  # something needs changing
      $self->_Modify_Values(
        sub{ __walk_worker(shift,0,$stringify,$maxstringwidth,$truncsuf) } );
    }
  }

  my @values = $self->Values;
  if ($debug) {
    say "##Vis Values(count ",scalar(@values),"): @values\n";
    say "##Vis Useqq = ", debugvis($self->Useqq);
  }
  if (@values != 1) {
    croak "Only a single scalar value (possibly a ref) is allowed by Vis"
      if @values >= 1;
    croak "No Values set"
  }

  # We always call Data::Dumper with Indent(0) and Pad("") to get a single
  # maximally-compact string, and then manually fold the result to Maxwidth,
  # and insert the user's Pad before each line.
  my $pad = $self->Pad();
  $self->Indent(0)->Pad("");
  {
    my ($sAt, $sQ) = ($@, $?); # Data::Dumper corrupts these
    $_ = $self->SUPER::Dump;
    ($@, $?) = ($sAt, $sQ);
  }
  $self->Pad($pad);
  $_ = $self->_postprocess_DD_result($_);

  &RestorePunct;
  $_
}

# Walk an arbitrary structure calling &coderef on each item. stopping
# The sub should return 1 to continue, or any other defined value to
# terminate the traversal early.
# Members of containers are visited after processing the container item itself,
# and containerness is checked after &$coderef returns so that &$coderef
# may transform the item (by reference through $_[0]) e.g. to replace a
# container with a scalar.
# RETURNS: The final $&coderef return val
sub __walk($$;$);
sub __walk($$;$) {  # (coderef, item [, seenhash])
  no warnings 'recursion';
  my $seen = $_[2] // {};
  # Test for recursion both before and after calling the coderef, in case the
  # code unconditionally clones or otherwise replaces the item with new data.
  if (reftype($_[1])) {
    my $refaddr0 = refaddr($_[1]);
    return 1 if $seen->{$refaddr0}; # increment only below
  }
  # Now call the coderef and re-check the item
  my $r = &{ $_[0] }($_[1]);
  return $r unless (my $reftype = reftype($_[1])); # no longer a container?
  my $refaddr1 = refaddr($_[1]);
  return $r if $seen->{$refaddr1}++;
  return $r unless $r eq "1";
  if ($reftype eq 'ARRAY') {
    foreach (@{$_[1]}) {
      my $r = __walk($_[0], $_, $seen);
      return $r unless $r eq "1";
    }
  }
  elsif ($reftype eq 'HASH') {
    #foreach (values %{$_[1]})
    #  return 0 unless __walk($_[0], $_, $seen);
    #}
    # sort to retain same visitation order in cloned copy
    foreach (sort keys %{$_[1]}) {
      my $r = __walk($_[0], $_[1]->{$_}, $seen);
      return $r unless $r eq "1";
    }
  }
  1
}

# __walk() is called with the specified subref on the
# array of Values in the object.  The sub should not modify anything,
# but may return other than "1" to terminate the traversal.
# Returns the last value returned by the visitor sub.
sub _Visit_Values {
  my ($self, $coderef) = @_;
  my @values = $self->Values;
  __walk($coderef, \@values);
}

# Edit Values: __walk() is called with the specified subref on the
# array of Values in the object.  The Values are cloned first to
# avoid corrupting the user's data structure.
# The sub should return only 1, or 0 to terminate the traversal early.
sub _Modify_Values {
  my ($self, $coderef) = @_;
  my @values = $self->Values;
  unless ($self->{VisCloned}++) {
    require Clone;
    @values = map{ Clone::clone($_) } @values;
  }
  my $r = __walk($coderef, \@values);
  confess "bug" unless $r =~ /^[01]$/;
  $self->Values(\@values);
}

sub show_as_number(_) { # Derived from JSON::PP version 4.02
  my $value = shift;
  return unless defined $value;
  no warnings 'numeric';
  # if the utf8 flag is on, it almost certainly started as a string
  return if utf8::is_utf8($value);
  # detect numbers
  # string & "" -> ""
  # number & "" -> 0 (with warning)
  # nan and inf can detect as numbers, so check with * 0
  return unless length((my $dummy = "") & $value);
  return unless 0 + $value eq $value;
  return 1 if $value * 0 == 0;
  return -1; # inf/nan
}

# Split keys into "components" (e.g. 2_16.A has 3 components) and sort each
# component numerically if the corresponding items are both numbers.
sub __sortkeys {
  my $hash = shift;
  return [
    sort { my @a = split /([_\W])/,$a;
           my @b = split /([_\W])/,$b;
           for (my $i=0; $i <= $#a; ++$i) {
             return 1 if $i > $#b;  # a is longer
             my $r = ($a[$i] =~ /^\d+$/ && $b[$i] =~ /^\d+$/)
                      ? ($a[$i] <=> $b[$i]) : ($a[$i] cmp $b[$i]) ;
             return $r if $r != 0;
           }
           return -1 if $#a < $#b; # a is shorter
           return 0;
         }
         keys %$hash
  ]
}

# FIXME: These don't take into account quoted strings in the interior!
our $curlies_re = RE_balanced(-parens=>'{}');
our $parens_re = RE_balanced(-parens=>'()');
our $curliesorsquares_re = RE_balanced(-parens=>'{}[]');

my $qquote_re = qr/"(?:[^"\\]++|\\.)*+"/;
my $squote_re = qr/'(?:[^'\\]++|\\.)*+'/;
my $quote_re = qr/${qquote_re}|${squote_re}/;

# These never match spaces (except as part of a quote)
my $nonquote_atom_re 
      = qr/ (?: [^,;\{\}\[\]"'\s]++ | \\["'] )++ | [,;\{\}\[\]] /xs; 
my $atom_re = qr/ $quote_re | $nonquote_atom_re /x;


#my $nonbracket_nonquote_atom_re = qr/
#       sub\ ${curlies_re}     # sub stub or arbitrary code with Deparse(1)
#    # | 0x\{[a0fA-F0-9]+\}     # hex escape
#     | \\[0-7]{1,3}+          # octal escape
#     | -?\.?\d[-\d\.eE]*+ | (?i:NaN|[-+]?Inf)  # number
#     | \([A-Z][\w:]++\)       # (stringification prefix)
#     | bless\( | \)
#     | \b[A-Za-z_]\w*+\b      # bareword e.g. hash key
#     | =>
#     | \\  # just a take-reference operator.  PROBLEM?
#     | [\*:]    # e.g. in glob refs fully::qualified::names
#   #  | [\$=;]   # so we can parse Indent(>0) with "$VAR1 = ... ;"
#     | ,
#     # DOES NOT INCLUDE top-level white space
#/x;
#my $nonquote_atom_re = qr/
#       ${nonbracket_nonquote_atom_re} | [\[\]\{\}] /x;
#my $nonbracket_atom_re = qr/
#       ${nonbracket_nonquote_atom_re} | ${quote_re} /x;
#my $atom_re = qr/ ${nonbracket_atom_re} | [\[\]\{\}] /x;

################ TEMP TEST
#'{k => "v"}' =~ /\A${nonquote_atom_re}/ or die;
#'{k => "v"}' =~ /\A(?: ${nonquote_atom_re} | ${quote_re} )++(?<t>.*)/xs or die;
#say "##TEST t=($+{t})";
#'{k => "v"}' =~ /\A(?: ${nonquote_atom_re} | ${quote_re} )++\z/xs or die;

sub __adjust_spacing() { # edits $_ in place
  #BUG HERE will corrupt interior of quoted strings
  #s/\s\s+/ /sg;              # condense e.g. sub{...} with Deparse(1) 
  #s/([\]\}],)(\S)/$1\ $2/sg;  # add space after ],
  
#  { oops if defined(pos);
#    while (!/\G\z/sgc) {
#      if (/\G${nonquote_atom_re}/sgc) {}
#      elsif (/\G${quote_re}/sgc)      {}
#      elsif (/\G\s/sgc)               {}
#      else {
#        oops "regex problem: Parse failed at '",substr($_,pos,1),"', pos ${\pos} of «$_»";
#      }
#    }
#    /\G./sg && oops;
#    oops "pos=${\pos} str=",debugvis($_) if defined(pos);
#  }
#
#  ### TEMP? Just verify that we can parse everything
#  ### (probably redundant with 'unmatched tail' check in __fold)
#  /\A(?: ${nonquote_atom_re} | ${quote_re} | \s+ )+\z/xs or oops "regex problem($_)";
  { oops if defined(pos);
    while (!/\G\z/sgc) {
      if (/\G${atom_re}\s*/sgc) {}
      else {
        oops "regex problem: Parse failed at '",substr($_,pos,1),"', pos ${\pos} of «$_»";
      }
    }
    /\G./sg && oops;
    oops "pos=${\pos} str=",debugvis($_) if defined(pos);
  }

  ### TEMP? Just verify that we can parse everything
  ### (probably redundant with 'unmatched tail' check in __fold)
  /\A(?: ${atom_re} | \s+ )+\z/xs or oops "regex problem($_)";

  s( $quote_re ?+ \K 
     ( (?: \bsub\s*${curlies_re} | $nonquote_atom_re | \s+)*+
     ) )
   ( do {
       local $_ = $1;
       s/\s+/ /sg;   # remove all unnecessary spaces
       s/\ (?![\$\@])//g;
       s/=>/ => /g;  # put back around  =>
       s/\[,/\[, /g; # after ],
       s/\bsub\ ?(${curlies_re})/"sub { ".substr($1,1,length($1)-2)." }"/eg;
       $_
     }
   )exsg;
}#__adjust_spacing

sub __fold($$) { # edits $_ in place
  my ($maxwid, $pad) = @_;

  say "## fold input (maxwid=$maxwid):", debugvis($_);
  say "## pad:", debugvis($pad);
 
  $maxwid = INT_MAX if $maxwid==0;  # no folding, but maybe space adjustments
  $maxwid -= length($pad);
  my $smidgen = min(5, int($maxwid / 6));

  pos = 0;
  my $prev_indent = 0;
  my $next_indent = 0;
  our $ind; local $ind = 0;
  my sub __ind_adjustment(;$) {
    say "@{_}atom=<<$^N>> pos=${\pos} p_indent=$prev_indent n_indent=$next_indent ind=$ind mw=$maxwid,$smidgen";
    local $_ = $^N;;
    /^["']/ ? 0 : ( (()=/[\[\{\(]/) - (()=/[\]\}\)]/) );
  }
  s(\G
    (?{ say "##Visfold at top: pos=",u(pos)," ->«",substr($_,pos//0),"»" })
    (?{ local $ind = $next_indent }) # initialize localized var
    (
      (\s*${atom_re},?+)  # at least one even if too wide
      (?{ local $ind = $ind + __ind_adjustment("First ") })
      (?:
          \s*
          (${atom_re},?+)
          (?{ local $ind = $ind + __ind_adjustment("Cont  ") })
          (?(?{ my $len = $prev_indent + pos() - $-[0];
                $len <= ($^N eq "[" ? $maxwid-$smidgen : $maxwid)
              })|(*FAIL))
      )*+
    )
    (?{ $next_indent = $ind }) # copy to non-localized storage
    (?<extra>\s*)
    (?{ say "##Visfold SUCCEEDED: pos=",u(pos) })
   )(do{
       my $len = length($1);
       if ($len > $maxwid) {
         #say "##VisFFOL over-long pos=${\pos} (prev_indent=$prev_indent next_indent=$next_indent len=$len mw=$maxwid)\n«$1»";
       } else {
         #say "##VisFFOL ok len    pos=${\pos} (prev_indent=$prev_indent next_indent=$next_indent len=$len mw=$maxwid)\n«$1»";
       }
       my $indent = $prev_indent;
       $prev_indent = $next_indent;
       $pad . (" " x $indent) . $1 ."\n"
     }
   )exsg
    or oops "\nnot matched (pad='$pad' maxwid=$maxwid):\n", debugvis($_),"\n";
  s/\n\z//
    or oops "unmatched tail (pad='${pad}') in:\n",debugvis($_);
  #say "## fold RESULT:", debugvis($_);
}#__fold

sub __unescape_printables() {
  # Data::Dumper outputs wide characters as escapes with Useqq(1).
  #say "__un INPUT:$_";

  s( \G (${atom_re}) (?<trailing>\s*)
   )( do{
        local $_ = $1;
        if (/^"/) {  # "double quoted string
          s{ (?: [^\\]++ | \\(?!x) )*+ \K ( \\x\{ (?<hex>[a-fA-F0-9]+) \} )
           }{
              #say "Maybe converting $+{hex} from '$1'";
              my $c;
              length($+{hex}) <= 6 
                && ($c = chr(hex($+{hex}))) !~ m<\P{XPosixGraph}|[\0-\377]> 
              ? $c : $1
           }xesg;
        }
        $_
      }.$+{trailing}
   )xesg;
}

sub _postprocess_DD_result {
  (my $self, local $_) = @_;

  my ($debug, $vistype, $maxwidth)
    = @$self{qw/VisDebug VisType Maxwidth/};

  croak "invalid VisType ", u($vistype)
    unless ($vistype//0) =~ /^(?:[salh]|hl)$/;

  say "##RAW  :",$_ if $self->{VisDebug};

  s/(['"])\Q$magic_num_prefix\E(.*?)(\1)/$2/sg;
  s/\Q$magic_numstr_prefix\E//sg;

  __unescape_printables;
  __adjust_spacing;
  __fold($maxwidth, $self->Pad());

  if (($vistype//"s") eq "s") {
  }
  elsif ($vistype eq "a") {
    oops debugvis($_) unless s/\A\[/(/ && s/\]\z/)/s;
  }
  elsif ($vistype eq "l") {
    oops unless s/\A\[// && s/\]\z//s;
  }
  elsif ($vistype eq "h") {
    oops($_) unless s/\A\{/(/ && s/\}\z/)/s;
  }
  elsif ($vistype eq "hl") {
    oops($_) unless s/\A\{// && s/\}\z//s;
  }
  else {
    oops "invalid VisType '$vistype'\n";
  }

  $_
} #_postprocess_DD_result {

my $sane_cW = $^W;
our @save_stack;
sub ResavePunct() {
  @{ save_stack[0] } = ( $@, $!+0, $^E+0, $,, $/, $\, $^W );
}
sub SaveAndResetPunct() {
  # Save things which will later be restored, and reset to sane values.
  push @save_stack, [];
  ResavePunct;
  $,  = "";       # output field separator is null string
  $/  = "\n";     # input record separator is newline
  $\  = "";       # output record separator is null string
  $^W = $sane_cW; # our load-time warnings
}
sub RestorePunct() {
  ( $@, $!, $^E, $,, $/, $\, $^W ) = pop @save_stack;
  # Erase other package variables which might refer to user objects
  # which would otherwise not be destroyed when expected
  # FIXME are these obsolete?
  undef @Vis::result; undef $Vis::evalarg; #????
}

1;
 __END__

TODO: put updated =pod back

#!/usr/bin/perl
# Tester for module Vis.  TODO: Convert to CPAN module-test setup
use strict; use warnings ; use feature qw(state say);
say "FIXME: Test qr/.../ as values to be dumped.";
  #use Regexp::Common qw/RE_balanced/;
  #my $re = RE_balanced(-parens=>'(){}[]');
use utf8;
use open IO => 'utf8', ':std';
select STDERR; $|=1; select STDOUT; $|=1;
use Scalar::Util qw(blessed reftype looks_like_number);
use Carp;
use English qw( -no_match_vars );;
use Data::Compare qw(Compare);
#use Guard qw(scope_guard);

# This script was written before the author knew anything about standard
# Perl test-harness tools.  Perhaps someday it will be wholely rewritten.
# Meanwhile, some baby steps...
use Test::More;
use Test::Deep qw(cmp_deeply);

#use lib "$ENV{HOME}/lib/perl";

my $unicode_str;

# We want to test the original version of the internal function
# Data::Dumper::qquote to see if the useqq="utf8" feature has been fixed, and
# if not allow Vis to over-ride it.  But perl nowadays seems to cache the sub
# lookup immediately in Data::Dumper, making the override ineffective.
#
# As of Vis v1.146 Vis no longer overrides that internal function,
# but instead parses hex escape sequences in output strings.
# So this test is just to detect if Useqq('utf8') is made to work in the future.
#
BEGIN{
  # [Obsolete comment:]
  #   This test must be done before loading Vis, which over-rides an internal
  #   function to fix the bug
  $unicode_str = join "", map { chr($_) } (0x263A .. 0x2650);
  require Data::Dumper;
  print "Loaded ", $INC{"Data/Dumper.pm"}, " qquote=", \&Data::Dumper::qquote,"\n";
  { my $s = Data::Dumper->new([$unicode_str],['unicode_str'])->Terse(1)->Useqq('utf8')->Dump;
    chomp $s;
    $s =~ s/^"(.*)"$/$1/s or die "bug";
    if ($s ne $unicode_str) {
      #warn "Data::Dumper with Useqq('utf8'):$s\n";
      warn "Note: Useqq('utf8') is broken in your Data::Dumper.\n"
    } else {
      print "Useqq('utf8') seems to have been fixed in Data::Dumper !!! \n";
      die "Consider changing Vis to not bother parsing hex escapes?";
    }
  }
}

use Vis;
print "Loaded ", $INC{"Vis.pm"}, "\n";

# Do an initial read of $[ so arybase will be autoloaded
# (prevents corrupting $!/ERRNO in subsequent tests)
eval '$[' // die;

sub unix_compatible_os() {
  state $result //=
    # There must be a better way...
    (($^O !~ /win|dos/i && $^O =~ /ix$|ux$|bsd|svr|uni|osf|sv$/)
     || $^O eq 'darwin'
     || $^O eq 'cygwin'
    )
    && -w "/dev/null";
  $result;
}
sub tf($) { $_[0] ? "true" : "false" }

sub fmt_codestring($;$) { # returns list of lines
  my ($str, $prefix) = @_;
  $prefix //= "line ";
  my $i=1; map{ sprintf "%s%2d: %s\n", $prefix,$i++,$_ } (split /\n/,$_[0]);
}

sub timed_run(&$@) {
  my ($code, $maxcpusecs, @codeargs) = @_;
  use Time::HiRes qw(clock);
  my $startclock = clock();
  my (@result, $result);
  if (wantarray) {@result = &$code(@codeargs)} else {$result = &$code(@codeargs)};
  my $cpusecs = clock() - $startclock;
  confess "TOOK TOO LONG ($cpusecs CPU seconds vs. limit of $maxcpusecs)\n"
    if $cpusecs > $maxcpusecs;
  if (wantarray) {return @result} else {return $result};
}

# check $code_display, qr/$exp/, $doeval->($code, $item) ;
# { my $code="Vis->new->hvis(k=>'v');"; check $code, '(k => "v")',eval $code }
sub check($$@) {
  my ($code, $expected_arg, @actual) = @_;
  local $_;  # preserve $1 etc. for caller
  say "##TTcheck code=«$code»\n  expected_arg=«$expected_arg»\n  actual=(@actual)"; 
  my @expected = ref($expected_arg) eq "ARRAY" ? @$expected_arg : ($expected_arg);
  die "ARE WE USING THIS FEATURE?" if @actual > 1;
  die "ARE WE USING THIS FEATURE?" if @expected > 1;
  confess "\nTESTa FAILED: $code\n"
         ."Expected ".scalar(@expected)." results, but got ".scalar(@actual).":\n"
         ."expected=(@expected)\n"
         ."actual=(@actual)\n"
         ."\$@=$@\n"
    if @expected != @actual;
  foreach my $i (0..$#actual) {
    my $actual = $actual[$i];
    my $expected = $expected[$i];
    if (ref($expected) eq "Regexp") {
      confess "\nTESTb FAILED: ",$code,"\n"
             ."Expected (Regexp):u\n".${expected}."«end»\n"
             ."Got:\n".u($actual)."«end»\n"
             ."Vis::Maxwidth = $Vis::Maxwidth\n"
        unless $actual =~ ($expected // "Never Matched");
    } else {
      confess "\nTESTc FAILED: $code\n"
             ."Expected:\n".u($expected)."«end»\n"
             ."Got:\n".u($actual)."«end»\n"
             ."Vis::Maxwidth = $Vis::Maxwidth\n"
             .Data::Dumper->new([$expected,$actual],['e','a'])->Dump
        unless (!defined($actual) && !defined($expected))
               || (defined($actual) && defined($expected) && $actual eq $expected);
    }
  }
}

# Run a variety of tests on an item which is a string or strigified object
# which is not presented as a bare number (i.e. it is shown in quotes).
# The caller provides a sub which does the eval in the desired context,
# for example with "use bignum".
# The expected_re matches the item without surrounding quotes.
sub checkstringy(&$$) {
  my ($doeval, $item, $expected_re) = @_;
  my $expqq_re = "\"${expected_re}\"";
  my $expq_re  = "'${expected_re}'";
  foreach (
    [ 'Vis->new()->vis($_[1])',  '_Q_' ],
    [ 'vis($_[1])',              '_Q_' ],
    [ 'visq($_[1])',             '_q_' ],
    [ 'avis($_[1])',             '(_Q_)' ],
    [ 'avisq($_[1])',            '(_q_)' ],
    #currently broken due to $VAR problem: [ 'avisq($_[1], $_[1])',     '(_q_, _q_)' ],
    [ 'lvis($_[1])',             '_Q_' ],
    [ 'lvisq($_[1])',            '_q_' ],
    [ 'svis(\'$_[1]\')',         '_Q_' ],
    [ 'svis(\'foo$_[1]\')',      'foo_Q_' ],
    [ 'svis(\'foo$\'."_[1]")',   'foo_Q_' ],
    [ 'dvis(\'$_[1]\')',         '$_[1]=_Q_' ],
    [ 'dvis(\'foo$_[1]bar\')',   'foo$_[1]=_Q_bar' ],
    [ 'dvisq(\'foo$_[1]\')',     'foo$_[1]=_q_' ],
    [ 'dvisq(\'foo$_[1]bar\')',  'foo$_[1]=_q_bar' ],
    [ 'vis({ aaa => $_[1], bbb => "abc" })', '{aaa => _Q_,bbb => "abc"}' ],
  ) {
    my ($code, $exp) = @$_;
    $exp = quotemeta $exp;
    $exp =~ s/_Q_/$expqq_re/g;
    $exp =~ s/_q_/$expq_re/g;
    my $code_display = $code . " with \$_[1]=«$item»";
    local $Vis::Maxwidth = 0;  # disable wrapping
    check $code_display, qr/$exp/, $doeval->($code, $item) ;
  }
}

# Run a variety of tests on non-string item, i.e. something which is a
# number or structured object (which might contains strings within, e.g.
# values or quoted keys in a hash).
#
# The given regexp specifies the expected result with Useqq(1), i.e.
# double-quoted; a single-quoted version is derived internally.
sub checklit(&$$) {
  my ($doeval, $item, $dq_expected_re) = @_;
  (my $sq_expected_re = $dq_expected_re) 
    =~ s{ ( [^\\"]++|(\\.) )*+ \K " }{'}xsg
       or do{ die "bug" if $dq_expected_re =~ /(?<![^\\])'/; }; #probably
  say "dq_expected_re=$dq_expected_re";
  say "sq_expected_re=$sq_expected_re";
  foreach (
    [ 'Vis->new()->vis($_[1])',  '_Q_' ],
    [ 'vis($_[1])',              '_Q_' ],
    [ 'visq($_[1])',             '_q_' ],
    [ 'avis($_[1])',             '(_Q_)' ],
    [ 'avisq($_[1])',            '(_q_)' ],
    #currently broken due to $VAR problem: [ 'avisq($_[1], $_[1])',     '(_q_, _q_)' ],
    [ 'lvis($_[1])',             '_Q_' ],
    [ 'lvisq($_[1])',            '_q_' ],
    [ 'svis(\'$_[1]\')',         '_Q_' ],
    [ 'svis(\'foo$_[1]\')',      'foo_Q_' ],
    [ 'svis(\'foo$\'."_[1]")',   'foo_Q_' ],
    [ 'dvis(\'$_[1]\')',         '$_[1]=_Q_' ],
    [ 'dvis(\'foo$_[1]bar\')',   'foo$_[1]=_Q_bar' ],
    [ 'dvisq(\'foo$_[1]\')',     'foo$_[1]=_q_' ],
    [ 'dvisq(\'foo$_[1]bar\')',  'foo$_[1]=_q_bar' ],
    [ 'vis({ aaa => $_[1], bbb => "abc" })', '{aaa => _Q_,bbb => "abc"}' ],
  ) {
    my ($code, $exp_template) = @$_;
    my $exp = quotemeta $exp_template;
    $exp =~ s/_Q_/$dq_expected_re/g;
    $exp =~ s/_q_/$sq_expected_re/g;
    my $code_display = $code . " with \$_[1]=«$item»";
    local $Vis::Maxwidth = 0;  # disable wrapping
    check $code_display, qr/$exp/, $doeval->($code, $item) ;
  }
}

# ---------- Check stuff other than formatting or interpolation --------

print "Vis::VERSION = $Vis::VERSION\n";

for my $varname (qw(PREMATCH MATCH POSTMATCH)) {
  $_ = "test"; /(\w+)/;
  no strict 'vars';
  die "Vis imports high-overhead English ($varname)"
    if eval "defined \$Vis::$varname";
  die "EVAL ERR: $@ " if $@;
}

my $byte_str = join "",map { chr $_ } 10..30;

##################################################
# Check default $Vis::Maxwidth
##################################################
{ chomp( my $expected = `tput cols` );  # may default to 80 if no tty
  die "Expected initial Vis::Maxwidth to be undef" if defined $Vis::Maxwidth;
  { local $ENV{COLUMNS} = $expected + 13;
    vis(123);
    die "Vis::Maxwidth does not honor ENV{COLUMNS}" unless $Vis::Maxwidth == $expected + 13;
    undef $Vis::Maxwidth;  # re-enable auto-detect
  }
  die "bug: Vis::Maxwidth not undef" if defined($Vis::Maxwidth);
  if (unix_compatible_os()) {
    delete local $ENV{COLUMNS};
    vis(123);
    die "Vis::Maxwidth ",u($Vis::Maxwidth)," not defaulted correctly, expecting $expected" unless $Vis::Maxwidth == $expected;
    undef $Vis::Maxwidth;  # re-enable auto-detect
  }
  die "bug: Vis::Maxwidth not undef" if defined($Vis::Maxwidth);
  if (unix_compatible_os()) {
    delete local $ENV{COLUMNS};
    my $pid = fork();
    if ($pid==0) {
      require POSIX;
      die "bug" unless POSIX::setsid()==$$;
      POSIX::close $_ for (0,1,2);
      vis(123);
      exit($Vis::Maxwidth // 253);
    }
    waitpid($pid,0);
    die "Vis::Maxwidth defaulted to ", ($? >> 8)|($? & !0xFF), " (not $expected as expected)"
      unless $? == ($expected << 8);
    $? = 0;
  }
}

##################################################
# Check Useqq('utf8') support
##################################################
{
  my $vis_outstr = vis($unicode_str);
  chomp $vis_outstr;
  my $dd_outstr = Data::Dumper->new([$unicode_str],['unicode_str'])->Terse(1)->Useqq('utf8')->Dump;
  print "   unicode_str=\"$unicode_str\"\n";
  print "    Vis output=$vis_outstr\n";
  if (substr($vis_outstr,1,length($vis_outstr)-2) ne $unicode_str) {
    die "Unicode does not come through unmolested!";
  }
  print "   D::D output=$dd_outstr\n";
}

my $undef_as_false = undef;
if (! ref Vis->new()->Useqq(undef)) {
  warn "WARNING: Data::Dumper methods do not recognize undef boolean args as 'false'.\n";
  $undef_as_false = 0;
}

# Basic test of OO interfaces
{ my $code="Vis->new->vis('foo')  ;"; check $code, '"foo"',     eval $code }
{ my $code="Vis->new->avis('foo') ;"; check $code, '("foo")',   eval $code }
{ my $code="Vis->new->hvis(k=>'v');"; check $code, '(k => "v")',eval $code }
{ my $code="Vis->new->dvis('foo') ;"; check $code, 'foo',       eval $code }
{ my $code="Vis->new->svis('foo') ;"; check $code, 'foo',       eval $code }

foreach (
          ['Maxwidth',0,1,80,9999],
          ['MaxStringwidth',undef,0,1,80,9999],
          ['Truncsuffix',"","...","(trunc)"],
          ['Debug',undef,0,1],
          # Now the 'q' interfaces force Useqq(0) internally
          # ['Useqq',0,1,'utf8'],
          ['Quotekeys',0,1],
          ['Sortkeys',0,1,sub{ [ sort keys %{shift @_} ] } ],
          # Other than Indent(0) and Terse(1) are no longer supported
          # ['Terse',0,1],
          # ['Indent',0,1,2,3],
          ['Sparseseen',0,1,2,3],
        )
{
  my ($confname, @values) = @$_;
  my $testval = [123];
  foreach my $value (@values) {
    foreach my $base (qw(vis avis hvis lvis hlvis dvis svis)) {
      foreach my $q ("", "q") {
        my $dumper = $base . $q . "(42";
         $dumper .= ", 43" if $base =~ /^[ahl]/;
         $dumper .= ")";
        {
          my $v = eval "{ local \$Vis::$confname = \$value;
                          my \$obj = Vis->new();
                          \$obj->$dumper ;   # discard dump result
                          \$obj->$confname() # fetch effective setting
                        }";
        confess "bug:$@ " if $@;
        confess "\$Vis::$confname value is not preserved by $dumper\n",
            "(Set \$Vis::$confname=",u($value)," but $confname() returned ",u($v),")\n"
         unless (! defined $v and ! defined $value) || ($v eq $value);
        }
      }
    }
  }
}

# ---------- Check formatting or interpolation --------

sub MyClass::meth {
  my $self = shift;
  return @_ ? [ "methargs:", @_ ] : "meth_with_noargs";
}

# Many tests assume this
$Vis::Maxwidth = 72;

@ARGV = ('fake','argv');
$. = 1234;
$ENV{EnvVar} = "Test EnvVar Value";


my %toplex_h = ("" => "Emp", A=>111,"B B"=>222,C=>{d=>888,e=>999},D=>{},EEEEEEEEEEEEEEEEEEEEEEEEEE=>\42,F=>\\\43);
   # EEE... identifer is long to force linewrap
my @toplex_a = (0,1,"C",\%toplex_h,[],[0..9]);
my $toplex_ar = \@toplex_a;
my $toplex_hr = \%toplex_h;
my $toplex_obj = bless {}, 'MyClass';

our %global_h = %toplex_h;
our @global_a = @toplex_a;
our $global_ar = \@global_a;
our $global_hr = \%global_h;
our $global_obj = bless {}, 'MyClass';

our %maskedglobal_h = (key => "should never be seen");
our @maskedglobal_a = ("should never be seen");
our $maskedglobal_ar = \@maskedglobal_a;
our $maskedglobal_hr = \%maskedglobal_h;
our $maskedglobal_obj = bless {}, 'ShouldNeverBeUsedClass';

our %localized_h = (key => "should never be seen");
our @localized_a = ("should never be seen");
our $localized_ar = \@localized_a;
our $localized_hr = \%localized_h;
our $localized_obj = \%localized_h;

our $a = "global-a";  # used specially used by sort()
our $b = "global-b";

package A::B::C;
our %ABC_h = %main::global_h;
our @ABC_a = @main::global_a;
our $ABC_ar = \@ABC_a;
our $ABC_hr = \%ABC_h;
our $ABC_obj = $main::global_obj;

package main;

$_ = "GroupA.GroupB";
/(.*)\W(.*)/sp or die "nomatch"; # set $1 and $2

{ my $code = 'qsh("a b")';           check $code, '"a b"',  eval $code; }
{ my $code = 'qsh(undef)';           check $code, "undef",  eval $code; }
#qsh no longer accepts multiple args
#{ my $code = 'qsh("a b","c d","e",undef,"g",q{\'ab\'"cd"})';
#   check $code, ['"a b"','"c d"',"e","undef","g","''\\''ab'\\''\"cd\"'"], eval $code; }
#{ my $code = 'qshpath("a b")';       check $code, '"a b"',  eval $code; }
{ my $code = 'qshpath("~user")';     check $code, "~user",  eval $code; }
{ my $code = 'qshpath("~user/a b")'; check $code, '~user/"a b"', eval $code; }
{ my $code = 'qshpath("~user/ab")';  check $code, "~user/ab", eval $code; }
{ my $code = 'qsh("~user/ab")';      check $code, '"~user/ab"', eval $code; }
{ my $code = 'qsh($_)';              check $code, "${_}",   eval $code; }
{ my $code = 'qsh()';                check $code, "${_}",   eval $code; }
{ my $code = 'qsh';                  check $code, "${_}",   eval $code; }
{ my $code = 'qshpath($_)';          check $code, "${_}",   eval $code; }
{ my $code = 'qshpath()';            check $code, "${_}",   eval $code; }
{ my $code = 'qshpath';              check $code, "${_}",   eval $code; }
{ my $code = 'forceqsh($_)';         check $code, "\"${_}\"", eval $code; }

# Basic checks
{ my $code = 'vis($_)'; check $code, "\"${_}\"", eval $code; }
{ my $code = 'vis()'; check $code, "\"${_}\"", eval $code; }
{ my $code = 'vis'; check $code, "\"${_}\"", eval $code; }
{ my $code = 'avis($_,1,2,3)'; check $code, "(\"${_}\",1,2,3)", eval $code; }
{ my $code = 'hvis("foo",$_)'; check $code, "(foo => \"${_}\")", eval $code; }
{ my $code = 'hlvis("foo",$_)'; check $code, "foo => \"${_}\"", eval $code; }
{ my $code = 'avis(@_)'; check $code, '()', eval $code; }
{ my $code = 'hvis(@_)'; check $code, '()', eval $code; }
{ my $code = 'hlvis(@_)'; check $code, '', eval $code; }
{ my $code = 'avis(undef)'; check $code, "(undef)", eval $code; }
{ my $code = 'hvis("foo",undef)'; check $code, "(foo => undef)", eval $code; }
{ my $code = 'vis(undef)'; check $code, "undef", eval $code; }
{ my $code = 'vis(\undef)'; check $code, "\\undef", eval $code; }
{ my $code = 'svis(undef)'; check $code, "<undef arg>", eval $code; }
{ my $code = 'dvis(undef)'; check $code, "<undef arg>", eval $code; }
{ my $code = 'dvisq(undef)'; check $code, "<undef arg>", eval $code; }

{ my $code = q/my $s; my @a=sort{ $s=dvis('$a $b'); $a<=>$b }(3,2); "@a $s"/ ;
  check $code, '2 3 a=3 b=2', eval $code;
}

# Vis v1.147ish+ : Check corner cases of re-parsing code 
{ my $code = q(my $v = undef; dvis('$v')); check $code, "v=undef", eval $code; }
{ my $code = q(my $v = \undef; dvis('$v')); check $code, "v=\\undef", eval $code; }
{ my $code = q(my $v = \"abc"; dvis('$v')); check $code, 'v=\\"abc"', eval $code; }
{ my $code = q(my $v = \"abc"; dvisq('$v')); check $code, "v=\\'abc'", eval $code; }
{ my $code = q(my $v = \*STDOUT; dvisq('$v')); check $code, "v=\\*::STDOUT", eval $code; }
{ my $code = q(open my $fh, "</dev/null" or die; dvis('$fh')); 
  check $code, "fh=\\*{\"::\\\$fh\"}", eval $code; }
{ my $code = q(open my $fh, "</dev/null" or die; dvisq('$fh')); 
  check $code, "fh=\\*{'::\$fh'}", eval $code; }

# Check that $1 etc. can be passed (this was once a bug...)
# The duplicated calls are to check that $1 is preserved
{ my $code = '" a~b" =~ / (.*)()/ && qsh($1); die unless $1 eq "a~b";qsh($1)'; 
  check $code, '"a~b"', eval $code; }
{ my $code = '" a~b" =~ / (.*)()/ && qshpath($1); die unless $1 eq "a~b";qshpath($1)'; 
  check $code, '"a~b"', eval $code; }
{ my $code = '" a~b" =~ / (.*)()/ && forceqsh($1); die unless $1 eq "a~b";forceqsh($1)'; 
  check $code, '"a~b"', eval $code; }
{ my $code = '" a~b" =~ / (.*)()/ && vis($1); die unless $1 eq "a~b";vis($1)'; 
  check $code, '"a~b"', eval $code; }
{ my $code = 'my $vv=123; \' a $vv b\' =~ / (.*)/ && dvis($1); die unless $1 eq "a \$vv b"; dvis($1)'; 
  check $code, 'a vv=123 b', eval $code; }

# Check Deparse support
{ my $data = eval 'BEGIN{ ${^WARNING_BITS} = 0 } no strict; no feature;
                   sub{ my $x = 42; };';
  { my $code = 'vis($data)'; check $code, "sub { \"DUMMY\" }", eval $code; }
  $Data::Dumper::Deparse = 1;
  { my $code = 'vis($data)'; check $code, "sub { my \$x=42; }", eval $code; }
}

# Floating point values (single values special-cased to show not as 'string')
{ my $code = 'vis(3.14)'; check $code, '3.14', eval $code; }
# But multiple values are sent through Data::Dumper, so...
{ my $code = 'vis([3.14])'; check $code, '[3.14]', eval $code; }

# bigint, bignum, bigrat support
#
# Recently Vis was changed to prepend (objtype) to stringified values,
# e.g. "(Math::BigFloat)3.14159265358979323846264338327950288419"
# but we might later change this back, or make the prefix optional;
# therefore we accept the result with or without with (type) prefix.

my $bigfstr = '9988776655443322112233445566778899.8877';
my $bigistr = '9988776655443322112233445566778899887766';
my $ratstr  = '1/9';

{
  use bignum;  # BigInt and BigFloat together

  # stringify everything possible
  local $Vis::Stringify = 1;  # NOTE: the '1' will be a BigInt !

  my $bigf = eval $bigfstr // die;
  die unless blessed($bigf) =~ /^Math::BigFloat/;
  checklit(sub{eval $_[0]}, $bigf, qr/(?:\(Math::BigFloat[^\)]*\))?${bigfstr}/);

  my $bigi = eval $bigistr // die;
  die unless blessed($bigi) =~ /^Math::BigInt/;
  checklit(sub{eval $_[0]}, $bigi, qr/(?:\(Math::BigInt[^\)]*\))?${bigistr}/);

  # Confirm that various Stringify values disable
  foreach my $Sval (0, undef, "", [], [0], [""]) {
    local $Vis::Stringify = $Sval;
    my $s = vis($bigf);
    die "bug(",u($Sval),")($s)" unless $s =~ /^\(?bless.*BigFloat/s;
  }
}
{
  use bigrat;
  my $rat = eval $ratstr // die;
  die unless blessed($rat) =~ /^Math::BigRat/;
  checklit(sub{eval $_[0]}, $rat, qr/(?:\(Math::BigRat[^\)]*\))?${ratstr}/);
}
{
  # no 'bignum' etc. in effect, just explicit class names
  use Math::BigFloat;
  my $bigf = Math::BigFloat->new($bigfstr);
  die unless blessed($bigf) =~ /^Math::BigFloat/;

  use Math::BigRat;
  my $rat = Math::BigRat->new($ratstr);
  die unless blessed($rat) =~ /^Math::BigRat/;

  # Without stringification
  { local $Vis::Stringify = 0;
    my $s = vis($bigf); die "bug($s)" unless $s =~ /^bless.*BigFloat/s;
  }
  # With explicit stringification of BigFloat only
  { local $Vis::Stringify = [qr/^Math::BigFloat/];
    checklit(sub{eval $_[0]}, $bigf, qr/(?:\(Math::BigFloat[^\)]*\))?${bigfstr}/);
    # But not other classes
    my $s = vis($rat); die "bug($s)" unless $s =~ /^bless.*BigRat/s;
  }
}

# Check string truncation, and that the original data is not modified in-place
{ my $orig_str  = '["abcDEFG",["xyzABCD",{longkey => "fghIJKL"}]]';
  my $check_data = eval $orig_str; die "bug" if $@;
  my $orig_data  = eval $orig_str; die "bug" if $@;
  foreach my $MSw (1..9) {
    # hand-truncate to create "expected result" data
    (my $exp_str = $orig_str) =~ s/\b([a-zA-Z]{$MSw})([a-zA-Z]*)/
                                    $1 . (length($2) > 3 && $1.$2 ne "longkey"
                                           ? "..." : $2)
                                  /seg;
    local $Vis::MaxStringwidth = $MSw;
    check "with MaxStringwidth=$MSw", $exp_str, eval 'vis($orig_data)';
    die "MaxStringwidth=$MSw : Original data corrupted"
      unless Compare($orig_data, $check_data);
  }
}

# There was a bug for s/dvis called direct from outer scope, so don't use eval:
check 
  'global divs %toplex_h',
  '%toplex_h=("" => "Emp",A => 111,"B B" => 222,C => {d => 888,e => 999}, D => {},'."\n"
    .' EEEEEEEEEEEEEEEEEEEEEEEEEE => \\42,F => \\\\\\43)',
  dvis('%toplex_h');
check 'global divs @ARGV', q(@ARGV=("fake","argv")), dvis('@ARGV');
check 'global divs $.', q($.=1234), dvis('$.');
check 'global divs $ENV{EnvVar}', q("Test EnvVar Value"), svis('$ENV{EnvVar}');
sub func {
  check 'func args', q(@_=(1,2,3)), dvis('@_');
}
func(1,2,3);

# There was once a "took almost forever" backtracking problem
my @backtrack_bugtest_data = (
  42,
  {A => 0, BBBBBBBBBBBBB => "foo"},
);
timed_run {
  check 'dvis @backtrack_bugtest_data',
        '@backtrack_bugtest_data=(42,{A => 0, BBBBBBBBBBBBB => "foo"})',
        dvis('@backtrack_bugtest_data');
} 0.01;

sub doquoting($$) {
  my ($input, $useqq) = @_;
  my $quoted = $input;
  if ($useqq) {
    $quoted =~ s/([\$\@"\\])/\\$1/gs;
    $quoted =~ s/\n/\\n/gs;
    $quoted =~ s/\t/\\t/gs;
    $quoted = "\"${quoted}\"";
  } else {
    $quoted =~ s/([\\'])/\\$1/gs;
    $quoted = "'${quoted}'";
  }
  return $quoted;
}

sub show_white($) {
  local $_ = shift;
  s/\t/<tab>/sg;
  s/( +)$/"<space>" x length($1)/seg;
  s/\n/<newline>/sg;
  $_
}

sub get_closure(;$) {
 my ($clobber) = @_;

 my %closure_h = (%toplex_h);
 my @closure_a = (@toplex_a);
 my $closure_ar = \@closure_a;
 my $closure_hr = \%closure_h;
 my $closure_obj = $toplex_obj;
 if ($clobber) { # try to over-write deleted objects
   @closure_a = ("bogusa".."bogusz");
 }

 return sub {

  # Perl is inconsistent about whether an eval in package DB can see
  # lexicals in enclosing scopes.  Sometimes it can, sometimes not.
  # However explicitly referencing those "global lexicals" in the closure
  # seems to make it work.
  #   5/16/16: Perl v5.22.1 *segfaults* if these are included
  #   (at least *_obj).  But removing them all causes some to appear
  #   to be non-existent.
  my $forget_me_not = [
     \$unicode_str, \$byte_str,
     \@toplex_a, \%toplex_h, \$toplex_hr, \$toplex_ar, \$toplex_obj,
     \@global_a, \%global_h, \$global_hr, \$global_ar, \$global_obj,
  ];

  # Referencing these intermediate variables also prevents them from
  # being destroyed before this closure is executed:
  my $saverefs = [ \%closure_h, \@closure_a, \$closure_ar, \$closure_hr, \$closure_obj ];


  my $zero = 0;
  my $one = 1;
  my $two = 2;
  my $EnvVarName = 'EnvVar';
  my $flex = 'Lexical in sub f';
  my $flex_ref = \$flex;
  my $ARGV_ref = \@ARGV;
  eval { die "FAKE DEATH\n" };  # set $@
  my %sublex_h = %toplex_h;
  my @sublex_a = @toplex_a;
  my $sublex_ar = \@sublex_a;
  my $sublex_hr = \%sublex_h;
  my $sublex_obj = $toplex_obj;
  our %subglobal_h = %toplex_h;
  our @subglobal_a = @toplex_a;
  our $subglobal_ar = \@subglobal_a;
  our $subglobal_hr = \%subglobal_h;
  our $subglobal_obj = $toplex_obj;
  our %maskedglobal_h = %toplex_h;
  our @maskedglobal_a = @toplex_a;
  our $maskedglobal_ar = \@maskedglobal_a;
  our $maskedglobal_hr = \%maskedglobal_h;
  our $maskedglobal_obj = $toplex_obj;
  local %localized_h = %toplex_h;
  local @localized_a = @toplex_a;
  local $localized_ar = \@toplex_a;
  local $localized_hr = \%localized_h;
  local $localized_obj = $toplex_obj;

  my @tests = (
    [ q(aaa\\\\bbb), q(aaa\bbb) ],

    #[ q($unicode_str\n), qq(unicode_str=\" \\x{263a} \\x{263b} \\x{263c} \\x{263d} \\x{263e} \\x{263f} \\x{2640} \\x{2641} \\x{2642} \\x{2643} \\x{2644} \\x{2645} \\x{2646} \\x{2647} \\x{2648} \\x{2649} \\x{264a} \\x{264b} \\x{264c} \\x{264d} \\x{264e} \\x{264f} \\x{2650}\"\n) ],
    [ q($unicode_str\n), qq(unicode_str="${unicode_str}"\n) ],

    # Now Data::Dumper outputs \x{...} escapes instead of octal
    #[ q($byte_str\n), qq(byte_str=\"\\n\\13\\f\\r\\16\\17\\20\\21\\22\\23\\24\\25\\26\\27\\30\\31\\32\\e\\34\\35\\36\"\n) ],
    [ q($byte_str\n), qq(byte_str=\"\\n\\x{B}\\f\\r\\x{E}\\x{F}\\x{10}\\x{11}\\x{12}\\x{13}\\x{14}\\x{15}\\x{16}\\x{17}\\x{18}\\x{19}\\x{1A}\\e\\x{1C}\\x{1D}\\x{1E}\"\n) ],

    [ q($flex\n), qq(flex=\"Lexical in sub f\"\n) ],
    [ q($$flex_ref\n), qq(\$\$flex_ref=\"Lexical in sub f\"\n) ],
    [ q($_ $ARG\n), qq(\$_=\"GroupA.GroupB\" ARG=\"GroupA.GroupB\"\n) ],
    [ q($a\n), qq(a=\"global-a\"\n) ],
    [ q($b\n), qq(b=\"global-b\"\n) ],
    [ q($1\n), qq(\$1=\"GroupA\"\n) ],
    [ q($2\n), qq(\$2=\"GroupB\"\n) ],
    [ q($3\n), qq(\$3=undef\n) ],
    [ q($&\n), qq(\$&=\"GroupA.GroupB\"\n) ],
    [ q(${^MATCH}\n), qq(\${^MATCH}=\"GroupA.GroupB\"\n) ],
    [ q($.\n), qq(\$.=1234\n) ],
    [ q($NR\n), qq(NR=1234\n) ],
    [ q($/\n), qq(\$/=\"\\n\"\n) ],
    [ q($\\\n), qq(\$\\=undef\n) ],
    [ q($"\n), qq(\$\"=\" \"\n) ],
    [ q($~\n), qq(\$~=\"STDOUT\"\n) ],
    [ q($^\n), qq(\$^=\"STDOUT_TOP\"\n) ],
    [ q($:\n), qq(\$:=\" \\n-\"\n) ],
    [ q($^L\n), qq(\$^L=\"\\f\"\n) ],
    [ q($?\n), qq(\$?=0\n) ],
    [ q($[\n), qq(\$[=0\n) ],
    [ q($$\n), qq(\$\$=$$\n) ],
    [ q($^N\n), qq(\$^N=\"GroupB\"\n) ],
    [ q($+\n), qq(\$+=\"GroupB\"\n) ],
    [ q(@+ $#+\n), qq(\@+=(13,6,13) \$#+=2\n) ],
    [ q(@- $#-\n), qq(\@-=(0,0,7) \$#-=2\n) ],
    #[ q($;\n), qq(\$;=\"\\34\"\n) ],
    [ q($;\n), qq(\$;=\"\\x{1C}\"\n) ],
    [ q(@ARGV\n), qq(\@ARGV=(\"fake\",\"argv\")\n) ],
    [ q($ENV{EnvVar}\n), qq(ENV{EnvVar}=\"Test EnvVar Value\"\n) ],
    [ q($ENV{$EnvVarName}\n), qq(ENV{\$EnvVarName}=\"Test EnvVar Value\"\n) ],
    [ q(@_\n), <<'EOF' ],  # N.B. Maxwidth was set to 72
@_=(42,
    [0,1,"C",
     {"" => "Emp", A => 111, "B B" => 222,
      C => {d => 888, e => 999}, D => {},
      EEEEEEEEEEEEEEEEEEEEEEEEEE => \42, F => \\\43
     },
     [],[0,1,2,3,4,5,6,7,8,9]
    ]
   )
EOF
    [ q($#_\n), qq(\$#_=1\n) ],
    [ q($@\n), qq(\$\@=\"FAKE DEATH\\n\"\n) ],
    map({
      my ($LQ,$RQ) = (/^(.)(.)$/) or die "bug";
      map({
        my $name = $_;
        map({
          my ($dollar, $r) = @$_;
          my $dolname_scalar = ($dollar ? "\$$dollar" : "").$name;
          my $p = " " x length("?${dollar}${name}_?${r}");
          [ qq(%${dollar}${name}_h${r}\\n), <<EOF ],
\%${dollar}${name}_h${r}=("" => "Emp", A => 111, "B B" => 222,
${p}  C => {d => 888, e => 999}, D => {},
${p}  EEEEEEEEEEEEEEEEEEEEEEEEEE => \\42, F => \\\\\\43
${p} )
EOF
          [ qq(\@${dollar}${name}_a${r}\\n), <<EOF ],
\@${dollar}${name}_a${r}=(0,1,"C",
${p}  {"" => "Emp", A => 111, "B B" => 222,
${p}   C => {d => 888, e => 999}, D => {},
${p}   EEEEEEEEEEEEEEEEEEEEEEEEEE => \\42, F => \\\\\\43
${p}  },
${p}  [],[0,1,2,3,4,5,6,7,8,9]
${p} )
EOF
          [ qq(\$#${dollar}${name}_a${r}),    qq(\$#${dollar}${name}_a${r}=5)   ],
          [ qq(\$#${dollar}${name}_a${r}\\n), qq(\$#${dollar}${name}_a${r}=5\n) ],
          [ qq(\$${dollar}${name}_a${r}[3]{C}{e}\\n),
            qq(${dolname_scalar}_a${r}[3]{C}{e}=999\n)
          ],
          [ qq(\$${dollar}${name}_a${r}[3]{C}{e}\\n),
            qq(${dolname_scalar}_a${r}[3]{C}{e}=999\n)
          ],
          [ qq(\$${dollar}${name}_a${r}[3]->{A}\\n),
            qq(${dolname_scalar}_a${r}[3]->{A}=111\n)
          ],
          [ qq(\$${dollar}${name}_a${r}[3]->{$LQ$RQ}\\n),
            qq(${dolname_scalar}_a${r}[3]->{$LQ$RQ}="Emp"\n)
          ],
          [ qq(\$${dollar}${name}_a${r}[3]{C}->{e}\\n),
            qq(${dolname_scalar}_a${r}[3]{C}->{e}=999\n)
          ],
          [ qq(\$${dollar}${name}_a${r}[3]->{C}->{e}\\n),
            qq(${dolname_scalar}_a${r}[3]->{C}->{e}=999\n)
          ],
          [ qq(\@${dollar}${name}_a${r}[\$zero,\$one]\\n),
            qq(\@${dollar}${name}_a${r}[\$zero,\$one]=(0,1)\n)
          ],
          [ qq(\@${dollar}${name}_h${r}{${LQ}A${RQ},${LQ}B B${RQ}}\\n),
            qq(\@${dollar}${name}_h${r}{${LQ}A${RQ},${LQ}B B${RQ}}=(111,222)\n)
          ],
        } (['',''], ['$','r'])
        ), #map [$dollar,$r]

        ( $] >= 5.022001 && $] <= 5.022001
            ?  (do{ state $warned = 0;
                    warn "\n\n** obj->method() tests disabled ** due to Perl v5.22.1 segfault!\n\n"
                     unless $warned++; ()
                  },())
            : (
               [ qq(\$${name}_obj->meth ()), qq(${name}_obj->meth="meth_with_noargs" ()) ],
               [ qq(\$${name}_obj->meth(42)), qq(${name}_obj->meth(42)=["methargs:",42]) ],
              )
        ),

        map({
          my ($dollar, $r, $arrow) = @$_;
          my $dolname_scalar = ($dollar ? "\$$dollar" : "").$name;
          [ qq(\$${dollar}${name}_h${r}${arrow}{\$${name}_a[\$two]}{e}\\n),
            qq(${dolname_scalar}_h${r}${arrow}{\$${name}_a[\$two]}{e}=999\n)
          ],
          [ qq(\$${dollar}${name}_a${r}${arrow}[3]{C}{e}\\n),
            qq(${dolname_scalar}_a${r}${arrow}[3]{C}{e}=999\n)
          ],
          [ qq(\$${dollar}${name}_a${r}${arrow}[3]{C}->{e}\\n),
            qq(${dolname_scalar}_a${r}${arrow}[3]{C}->{e}=999\n)
          ],
          [ qq(\$${dollar}${name}_h${r}${arrow}{A}\\n),
            qq(${dolname_scalar}_h${r}${arrow}{A}=111\n)
          ],
        } (['$','r',''], ['','r','->'])
        ), #map [$dollar,$r,$arrow]
        }
        qw(closure sublex toplex global subglobal maskedglobal localized
           A::B::C::ABC)
      ), #map $name
      } ('""', "''")
    ), #map ($LQ,$RQ)
  );
  for my $tx (0..$#tests) {
    my $test = $tests[$tx];
    my ($dvis_input, $expected) = @$test;
    #warn "##^^^^^^^^^^^ dvis_input='$dvis_input' expected='$expected'\n";

    { local $@;  # check for bad syntax first, to avoid uncontrolled die later
      # For some reason we can't catch exceptions from inside package DB.
      # undef is returned but $@ is not set
      my $ev = eval { "$dvis_input" };
      die "Bad test string:$dvis_input\nPerl can't interpolate it"
         .($@ ? ":\n  $@" : "\n")
        if $@ or ! defined $ev;
    }

    my sub punctbug($$$) {
      my ($varname, $act, $exp) = @_;
      confess "ERROR (testing '$dvis_input'): $varname was not preserved (expected $exp, got $act)\n"
    }
    my sub checkspunct($$$) {
      my ($varname, $actual, $expecting) = @_;
      check "dvis('$dvis_input') : $varname NOT PRESERVED : ",
            $actual//"<undef>", $expecting//"<undef>" ;
    }
    my sub checknpunct($$$) {
      my ($varname, $actual, $expecting) = @_;
      # N.B. check() compaares as strings
      check "dvis('$dvis_input') : $varname NOT PRESERVED : ",
            defined($actual) ? $actual+0 : "<undef>",
            defined($expecting) ? $expecting+0 : "<undef>" ;
    }

    for my $use_oo (0,1) {
      my $actual;
      { # Verify that special vars are preserved and don't affect Vis
        # (except if testing a punctuation var, then don't change it's value)

        my ($origAt, $origFs, $origBs, $origComma, $origBang, $origCarE, $origCarW)
          = ($@, $/, $\, $,, $!, $^E, $^W);

        # Don't change a value if being tested in $dvis_input
        my ($fakeAt, $fakeFs, $fakeBs, $fakeComma, $fakeBang, $fakeCarE, $fakeCarW)
          = ($dvis_input =~ /(?<!\\)\$@/    ? $origAt : "FakeAt",
             $dvis_input =~ /(?<!\\)\$\//   ? $origFs : "FakeFs",
             $dvis_input =~ /(?<!\\)\$\\\\/ ? $origBs : "FakeBs",
             $dvis_input =~ /(?<!\\)\$,/    ? $origComma : "FakeComma",
             $dvis_input =~ /(?<!\\)\$!/    ? $origBang : 6,
             $dvis_input =~ /(?<!\\)\$^E/   ? $origCarE : 6,  # $^E aliases $! on most OSs
             $dvis_input =~ /(?<!\\)\$^W/   ? $origCarW : 0); # $^W can only be 0 or 1

        ($@, $/, $\, $,, $!, $^E, $^W) = ($fakeAt, $fakeFs, $fakeBs, $fakeComma, $fakeBang,
                                          $fakeCarE, $fakeCarW);

        $actual = $use_oo
          ? Vis->dnew($dvis_input)->Dump   # <<<<<<<<<<<<<<< HERE
          : dvis($dvis_input);

        checkspunct('$@',  $@,   $fakeAt);
        checkspunct('$/',  $/,   $fakeFs);
        checkspunct('$\\', $\,   $fakeBs);
        checkspunct('$,',  $,,   $fakeComma);
        checknpunct('$!',  $!+0, $fakeBang);
        checknpunct('$^E', $^E+0,$fakeCarE);
        checknpunct('$^W', $^W+0,$fakeCarW);

        # Restore
        ($@, $/, $\, $,, $!, $^E, $^W)
          = ($origAt, $origFs, $origBs, $origComma, $origBang, $origCarE, $origCarW);
      }
      unless ($expected eq $actual) {
        confess "\ndvis (oo=$use_oo) test tx $tx failed: input «",
                show_white($dvis_input),"»\n",
                "Expected:\n",show_white($expected),"«end»\n",
                "Got:\n",show_white($actual),"«end»\n"
      }
    }

    # Check Useqq
    for my $useqq (0, 1) {
      my $input = $expected.$dvis_input.'qqq@_(\(\))){\{\}\""'."'"; # gnarly
      # Now Data::Dumper (version 2.174) forces "double quoted" output
      # if there are any Unicode characters present.
      # So we can not test single-quoted mode in those cases
      next
        if $input =~ tr/0-\377//c; #
      my $exp = doquoting($input, $useqq);
      my $act = Vis->new->Useqq($useqq)->dvis($input);
      die "\n\nUseqq ",u($useqq)," bug:\n"
         ."   Input   «${input}»\n"
         ."  Expected «${exp}»\n"
         ."       Got «${act}»\n "
        unless $exp eq $act;
    }
  }
 };
} # get_closure()
sub f($) {
  get_closure(1);
  my $code = get_closure(0);
  get_closure(1);
  get_closure(1);
  $code->(@_);
}
sub g($) {
  local $_ = 'SHOULD NEVER SEE THIS';
  goto &f;
}
&g(42,$toplex_ar);
print "Tests passed.\n";
exit 0;

# End Tester
