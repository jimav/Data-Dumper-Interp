# License: Public Domain or CC0
# See https://creativecommons.org/publicdomain/zero/1.0/
# The author, Jim Avera (jim.avera at gmail) has waived all copyright and
# related or neighboring rights.  Attribution is requested but is not required.

##FIXME: Blessed structures are not formatted because we treat bless(...) as an atom

use strict; use warnings FATAL => 'all'; use utf8;
#use 5.010;  # say, state
use 5.011;  # cpantester gets warning that 5.11 is the minimum acceptable
use 5.018;  # lexical_subs
use feature qw(say state lexical_subs current_sub);
use feature 'lexical_subs';

no warnings "experimental::lexical_subs";

package  Data::Dumper::Interp;
{ no strict 'refs'; ${__PACKAGE__."::VER"."SION"} = 997.999; }
# VERSION from Dist::Zilla::Plugin::OurPkgVersion
# DATE from Dist::Zilla::Plugin::OurDate

package
  # newline so Dist::Zilla::Plugin::PkgVersion won't add $VERSION
        DB {
  sub DB_Vis_Evalwrapper {
    eval $Data::Dumper::Interp::string_to_eval; ## no critic
  }
}

package Data::Dumper::Interp;

use Moose;
no warnings "experimental::lexical_subs"; # un-do Moose forcing these on!!

extends qw(Data::Visitor);

use Data::Dumper ();
use Carp;
use POSIX qw(INT_MAX);
use Scalar::Util qw(blessed reftype refaddr looks_like_number weaken);
use List::Util 1.33 qw(min max first none all any sum0);
use Regexp::Common qw/RE_balanced/;
use Term::ReadKey ();
use overload ();

use Exporter 'import';
our @EXPORT    = qw( visnew

                     vis visq avis avisq hvis hvisq
                     alvis alvisq hlvis hlvisq
                     viso visoq
                     rvis rvisq ravis ravisq rhvis rhvisq

                     ivis ivisq dvis dvisq
                     addrvis
                     u quotekey qsh qshlist qshpath
                   );

our @EXPORT_OK = qw($Debug $MaxStringwidth $Truncsuffix $Objects $Foldwidth
                    $Useqq $Quotekeys $Sortkeys
                    $Maxdepth $Maxrecurse $Deparse);

sub addrvis(_); # forward
#---------------------------------------------------------------------------
# Internal debug-message utilities

sub oops(@) { @_=("\n".__PACKAGE__." oops:\n",@_,"\n"); goto &Carp::confess }
sub btw(@) { local $_=join("",@_); s/\n\z//s; say( (caller(0))[2].": $_" ); }

sub __chop_loc($) {  # remove "at ..." from an exception message
  (local $_ = shift) =~ s/ at \(eval[^\)]*\) line \d+[^\n]*\n?\z//s;
  $_
}
sub _tf($) { $_[0] ? "T" : "F" }
sub _showfalse(_) { $_[0] ? $_[0] : 0 }
sub _dbvisnew {
  my $v = shift;
  Data::Dumper->new([$v])->Terse(1)->Indent(0)->Quotekeys(0)
              #->Useperl(1)
              ###->Sortkeys(\&__sortkeys)->Pair("=>")
}
sub _dbvis(_) {chomp(my $s=_dbvisnew(shift)->Useqq(1)->Dump); $s }
sub _dbvisq(_){chomp(my $s=_dbvisnew(shift)->Useqq(0)->Dump); $s }
sub _dbvis2(_){chomp(my $s=_dbvisnew(shift)->Maxdepth(3)->Useqq(1)->Dump); $s }
sub _dbavis(@){ "(" . join(", ", map{_dbvis} @_) . ")" }
sub _dbrvis(_) { (ref($_[0]) ? addrvis($_[0]) : "")._dbvis($_[0])  }
sub _dbrvis2(_){ (ref($_[0]) ? addrvis($_[0]) : "")._dbvis2($_[0]) }
sub _dbravis2(@){ "(" . join(", ", map{_dbrvis2} @_) . ")" }
sub _dbshow(_) {
  my $v = shift;
  blessed($v) ? "(".blessed($v).")".$v   # stringify with (classname) prefix
              : _dbvis($v)               # something else
}
our $_dbmaxlen = 300;
sub _dbrawstr(_) { "«".(length($_[0])>$_dbmaxlen ? substr($_[0],0,$_dbmaxlen-3)."..." : $_[0])."»" }
sub _dbstr($) {
  local $_ = shift;
  return "undef" if !defined;
  s/\x{0a}/\N{U+2424}/sg; # a special NL glyph
  s/ /\N{U+00B7}/sg;      # space -> Middle Dot
  s/[\x{00}-\x{1F}]/ chr( ord($&)+0x2400 ) /aseg;
  $_
}
sub _dbstrposn($$) {
  local $_ = shift;
  my $posn = shift;
  local $_dbmaxlen = max($_dbmaxlen+8, $posn+8);
  my $visible = _dbstr($_); # simplified 'controlpics'
  "posn=$posn shown at '(<<HERE)':"
    . substr($visible, 0, $posn+1)."(<<HERE)".substr($visible,$posn+1)
}
#---------------------------------------------------------------------------

#################### Configuration Globals #################

our ($Debug, $MaxStringwidth, $Truncsuffix, $Objects,
     $Foldwidth, $Foldwidth1,
     $Useqq, $Quotekeys, $Sortkeys,
     $Maxdepth, $Maxrecurse, $Deparse);

$Debug          = 0            unless defined $Debug;
$MaxStringwidth = 0            unless defined $MaxStringwidth;
$Truncsuffix    = "..."        unless defined $Truncsuffix;
$Objects        = 1            unless defined $Objects;
$Foldwidth      = undef        unless defined $Foldwidth;  # undef auto-detects
$Foldwidth1     = undef        unless defined $Foldwidth1; # override for 1st

# The following override Data::Dumper defaults
# Initial D::D values are captured once when we are first loaded.
#
#$Useqq          = "unicode:controlpic" unless defined $Useqq;
$Useqq          = "unicode"    unless defined $Useqq;
$Quotekeys      = 0            unless defined $Quotekeys;
$Sortkeys       = \&__sortkeys unless defined $Sortkeys;
$Maxdepth       = $Data::Dumper::Maxdepth   unless defined $Maxdepth;
$Maxrecurse     = $Data::Dumper::Maxrecurse unless defined $Maxrecurse;
$Deparse        = 0            unless defined $Deparse;

#################### Methods #################

# Other Data::Dumper options may be accessed via inherited methods from D::D.

# OK, trying this fully Moosified.  If it is too slow then I'll go back
# to using a separate Moose ...::Mapper class only used to clone/preprocess.

has dd => (
  is => 'ro',
  lazy => 1,
  isa => 'Data::Dumper',
  default => sub{
    my $self = shift;
    Data::Dumper->new([],[])
      ->Terse(1)
      ->Indent(0)
      ->Sparseseen(1)
      ->Useqq($Useqq)
      ->Quotekeys($Quotekeys)
      ->Sortkeys($Sortkeys)
      ->Maxdepth($Maxdepth)
      ->Maxrecurse($Maxrecurse)
      ->Deparse($Deparse)
  },
  handles => [qw/Values Useqq Quotekeys Trailingcomma Pad Varname Quotekeys
                 Maxdepth Maxrecurse Useperl Sortkeys Deparse
                /],
);

# Config values which have no counter part in Data::Dumper
has Debug          => (is=>'rw', default => sub{ $Debug                 });
has MaxStringwidth => (is=>'rw', default => sub{ $MaxStringwidth        });
has Truncsuffix    => (is=>'rw', default => sub{ $Truncsuffix           });
has Objects        => (is=>'rw', default => sub{ $Objects               });
has Foldwidth      => (is=>'rw', default => sub{
                         $Foldwidth // do{
                           $_[0]->_set_default_Foldwidth();
                           $Foldwidth
                         }
                       });
has Foldwidth1     => (is=>'rw', default => sub{ $Foldwidth1            });

sub _Vistype {
  my ($s, $v) = @_;
  # Replace anything other than 'r' (the addrvis-prefix flag).
  # This is so when rdvis() et al. reuses the object but we don't
  # loose 'r' flag after the first interpolcation.
  @_ >= 2 ? (($s->{_Vistype} = (index($s->{_Vistype}//"",'r')>=0 ? 'r':'').$v),
             return $s)
          : $s->{_Vistype}
}

# Make "setters" return the outer object $self
around       [qw/Values Useqq Quotekeys Trailingcomma Pad Varname Quotekeys
                 Maxdepth Maxrecurse Useperl Sortkeys Deparse

                 Debug MaxStringwidth Truncsuffix Objects
                 Foldwidth Foldwidth1 _Vistype
                /] => sub{
  my $orig = shift;
  my $self = shift;
  #Carp::cluck("##around (@_)\n");
  if (@_ > 0) {
    $self->$orig(@_);
    return $self;
  }
  $self->$orig
};

############### Utility Functions #################

#---------------------------------------------------------------------------
# Display an address as <decimal:hex> showing only the last few digits.
# The number of digits shown increases when collisions occur.
# The arg can be a numeric address or a ref from which the addr is taken.
# If a ref the result is REFTYPEorOBJTYPE<dec:hex> otherwise just <dec:hex>
our $addrvis_ndigits = 3;
our $addrvis_a2abv   = {}; # address => abbreviated digits
our $addrvis_abbrevs = {}; # abbreviated digits => undef
sub addrvis_forget(;$) {
  $addrvis_ndigits = $_[0] || 3;
  $addrvis_a2abv   = {};
  $addrvis_abbrevs = {};
}
sub addrvis(_) {
  my $arg = shift // return("undef");
  my $refstr = ref($arg);
  my $addr;
  if ($refstr ne "")              { $addr = refaddr($arg) }
  elsif (looks_like_number($arg)) { $addr = $arg }
  else {
    carp("addrvis arg '$arg' is neither a ref or a number\n");
    return ""
  }

  my sub abbr_hex($) {
       substr(sprintf("%0*x", $addrvis_ndigits, $_[0]), -$addrvis_ndigits) }
  my sub abbr_dec($) {
       substr(sprintf("%0*d", $addrvis_ndigits, $_[0]), -$addrvis_ndigits) }

  if (! exists $addrvis_a2abv->{$addr}) {
    my $abbrev = abbr_dec($addr);
    while (exists $addrvis_abbrevs->{$abbrev}) {
      ++$addrvis_ndigits;
      $addrvis_abbrevs = {};
      for my $old_a (keys %$addrvis_a2abv) {
        my $new_abbrev = abbr_dec($old_a);
        $addrvis_a2abv->{$old_a} = $new_abbrev;
        $addrvis_abbrevs->{$new_abbrev} = undef;
      }
      $abbrev = abbr_dec($addr);
    }
    $addrvis_a2abv->{$addr} = $abbrev;
    $addrvis_abbrevs->{$abbrev} = undef;
  }
  $refstr.'<'.abbr_dec($addr).':'.abbr_hex($addr).'>'
}

=for Pod::Coverage addrvis_forget

=cut

sub u(_) { $_[0] // "undef" }
sub quotekey(_); # forward.  Implemented after regex declarations.

sub __stringify($) {
  if (defined(my $class = blessed($_[0]))) {
    return "$_[0]" if overload::Method($class,'""');
  }
  $_[0]
}

use constant _SHELL_UNSAFE_REGEX =>
  ($^O eq "MSWin32" ? qr/[^-=\w_:\.,\\]/ : qr/[^-=\w_\/:\.,]/);

sub __forceqsh(_) {
  local $_ = shift;
  return "undef" if !defined;  # undef without quotes
  $_ = vis($_) if ref;
  if ($^O eq "MSWin32") {
    # Backslash usually need not be protected, except:
    #  \" quotes the " whether inside "quoes" or bare (!)
    #  \\ quotes the \ ONLY(?) if immediately followed by \"
    s/\\(?=")/\\\\/g;
    s/"/\\"/g;
    return "\"${_}\"";  # 6/7/23: UNtested
  } else {
    # Prefer "double quoted" if no shell escapes would be needed.
    if (/["\$`!\\\x{00}-\x{1F}\x{7F}]/) {
      # Unlike Perl, /bin/sh does not recognize any backslash escapes in '...'
      s/'/'\\''/g; # foo'bar => foo'\''bar
      return "'${_}'";
    } else {
      return "\"${_}\"";
    }
  }
}
sub qsh(_) {
  local $_ = __stringify(shift());
  defined && !ref && ($_ !~ _SHELL_UNSAFE_REGEX)
    && $_ ne "" && $_ ne "undef" ? $_ : __forceqsh
}
sub qshpath(_) {  # like qsh but does not quote initial ~ or ~username
  local $_ = __stringify(shift());
  return qsh($_) if !defined or ref;
  my ($tilde_prefix, $rest) = /^( (?:\~[^\/\\]*[\/\\]?+)? )(.*)/xs or die;
  $rest eq "" ? $tilde_prefix : $tilde_prefix.qsh($rest)
}

# Should this have been called 'aqsh' ?
sub qshlist(@) { join " ", map{qsh} @_ }

#---------------------------------------------------------------------------

my $sane_cW = $^W;
my $sane_cH = $^H;
our @save_stack;
sub _SaveAndResetPunct() {
  # Save things which will later be restored
  push @save_stack, [ $@, $!+0, $^E+0, $,, $/, $\, $?, $^W ];
  # Reset sane values
  $,  = "";       # output field separator is null string
  $/  = "\n";     # input record separator is newline
  $\  = "";       # output record separator is null string
  $?  = 0;        # child process exit status
  $^W = $sane_cW; # our load-time warnings
  #$^H = $sane_cH; # our load-time pragmas (strict etc.)
}
sub _RestorePunct_NoPop() {
  ( $@, $!, $^E, $,, $/, $\, $?, $^W ) = @{ $save_stack[-1] };
}
sub _RestorePunct() {
  &_RestorePunct_NoPop;
  pop @save_stack;
}

########### Subs callable as either a Function or Method #############

sub __getobj {
  # A tie handler might throw then $_[0] is referenced
  my $bl; do{ local $@; eval {$bl=blessed($_[0])}; croak __chop_loc($@) if $@ };
  $bl && $_[0]->isa(__PACKAGE__) ? shift : __PACKAGE__->new()
}
sub __getobj_s { &__getobj->Values([$_[0]]) }
sub __getobj_a { &__getobj->Values([\@_])   }
sub __getobj_h {
  my $o = &__getobj;
  (scalar(@_) % 2)==0 or croak "Uneven arg count for key => val pairs";
  $o->Values([{@_}])
}
sub __spacedots_getobj {
  local $Useqq = length($Useqq//"") > 1 ? $Useqq.":spacedots" : $Useqq;
  &__getobj
}

sub visnew()  { __PACKAGE__->new() }  # shorthand

# These can be called as *FUNCTIONS* or as *METHODS*
sub vis(_)    { &__getobj_s ->_Vistype('')                      ->_Do; }
sub visq(_)   { &__getobj_s ->_Vistype('')->Useqq(0)            ->_Do; }
sub avis(@)   { &__getobj_a ->_Vistype('a')                     ->_Do; }
sub avisq(@)  { &__getobj_a ->_Vistype('a')->Useqq(0)           ->_Do; }
sub hvis(@)   { &__getobj_h ->_Vistype('h')                     ->_Do; }
sub hvisq(@)  { &__getobj_h ->_Vistype('h')->Useqq(0)           ->_Do; }
    # '?l' variants return a bare List without parenthesis/brackets
sub alvis(@)  { &__getobj_a ->_Vistype('l')                     ->_Do; }
sub alvisq(@) { &__getobj_a ->_Vistype('l')->Useqq(0)           ->_Do; }
sub hlvis(@)  { &__getobj_h ->_Vistype('l')                     ->_Do; }
sub hlvisq(@) { &__getobj_h ->_Vistype('l')->Useqq(0)           ->_Do; }
    # 'o' variants show object internals
sub viso(_)   { &__getobj_s ->_Vistype('')->Objects(0)          ->_Do; }
sub visoq(_)  { &__getobj_s ->_Vistype('')->Objects(0)->Useqq(0)->_Do; }
    # 'r*' variants prefix ref expansions with type<abbrevaddr>
sub rvis(_)   { &__getobj_s ->_Vistype('r')                     ->_Do; }
sub rvisq(_)  { &__getobj_s ->_Vistype('r')->Useqq(0)           ->_Do; }
sub ravis(@)  { &__getobj_a ->_Vistype('ar')                    ->_Do; }
sub ravisq(@) { &__getobj_a ->_Vistype('ar')->Useqq(0)          ->_Do; }
sub rhvis(@)  { &__getobj_h ->_Vistype('hr')                    ->_Do; }
sub rhvisq(@) { &__getobj_h ->_Vistype('hr')->Useqq(0)          ->_Do; }

# Trampolines which replace the call frame with a call directly to the
# interpolation code which uses $package DB to access the user's context.
sub ivis(_) { @_=(&__getobj,          shift,'i');goto &_Interpolate }
sub ivisq(_){ @_=(&__getobj->Useqq(0),shift,'i');goto &_Interpolate }
sub dvis(_) { @_=(&__spacedots_getobj,          shift,'d');goto &_Interpolate }
sub dvisq(_){ @_=(&__getobj->Useqq(0),shift,'d');goto &_Interpolate }

sub rivis(_) { @_=(&__getobj->_Vistype('r')          ,shift,'i');goto &_Interpolate }
sub rivisq(_){ @_=(&__getobj->_Vistype('r')->Useqq(0),shift,'i');goto &_Interpolate }
sub rdvis(_) { @_=(&__spacedots_getobj->_Vistype('r'),shift,'d');goto &_Interpolate }
sub rdvisq(_){ @_=(&__getobj->_Vistype('r')->Useqq(0),shift,'d');goto &_Interpolate }

############# only internals follow ############

BEGIN {
  if (! Data::Dumper->can("Maxrecurse")) {
    # Supply if missing in older Data::Dumper
    eval q(sub Data::Dumper::Maxrecurse {
             my($s, $v) = @_;
             @_ == 2 ? (($s->{Maxrecurse} = $v), return $s)
                     : $s->{Maxrecurse}//0;
           });
    die $@ if $@;
  }
}

sub _get_terminal_width() {  # returns undef if unknowable
  if (u($ENV{COLUMNS}) =~ /^[1-9]\d*$/) {
    return $ENV{COLUMNS}; # overrides actual terminal width
  } else {
    local *_; # Try to avoid clobbering special filehandle "_"
    # This does not actualy work; https://github.com/Perl/perl5/issues/19142

    my $fh = -t STDERR ? *STDERR :
             -t STDOUT ? *STDOUT :
             -t STDIN  ? *STDIN  :
        do{my $fh; for("/dev/tty",'CONOUT$') { last if open $fh, $_ } $fh} ;
    my $wmsg = ""; # Suppress a "didn't work" warning from Term::ReadKey.
                   # On some platforms (different libc?) "stty" directly
                   # outputs "stdin is not a tty" which we can not trap.
                   # Probably this is a Term::Readkey bug where it should
                   # redirect such messages to /dev/null...
    my ($width, $height) = do {
      local $SIG{'__WARN__'} = sub { $wmsg .= $_[0] };
      $fh ? Term::ReadKey::GetTerminalSize($fh) : ()
    };
    return $width; # possibly undef (sometimes seems to be zero ?!?)
  }
}

sub _set_default_Foldwidth() {
  my $self = shift;
  _SaveAndResetPunct();
  $Foldwidth = _get_terminal_width || 80;
  _RestorePunct();
  undef $Foldwidth1;
}

my $unique = refaddr \&vis;
my $magic_noquotes_pfx   = "<NQMagic$unique>";
my $magic_keepquotes_pfx = "<KQMagic$unique>";
my $magic_addrvis        = "<AVMagic$unique>";
my $magic_elide_next     = "<ENMagic$unique>";

#---------------------------------------------------------------------------
my ($maxstringwidth, $truncsuffix, $objects, $vistype, $debug);

sub _Do {
  oops unless @_ == 1;
  my $self = $_[0];

  local $_;
  &_SaveAndResetPunct;

  ($maxstringwidth, $truncsuffix, $objects, $vistype, $debug)
    = @$self{qw/MaxStringwidth Truncsuffix Objects _Vistype Debug/};

  $maxstringwidth = 0 if ($maxstringwidth //= 0) >= INT_MAX;
  $truncsuffix //= "...";
  $objects = [ $objects ] unless ref($objects //= []) eq 'ARRAY';

  my @orig_values = $self->dd->Values;
  croak "Exactly one item may be in Values" if @orig_values != 1;
  my $original = $orig_values[0];
  btw "##ORIGINAL=",u($original),"=",_dbvis($original) if $debug;

  my $modified = $self->visit($original); # see Data::Visitor
  btw "##MODIFIED (DD input):",_dbvis($modified) if $debug;
  $self->dd->Values([$modified]);

  # Always call Data::Dumper with Indent(0) and Pad("") to get a single
  # maximally-compact string, and then manually fold the result to Foldwidth,
  # inserting the user's Pad before each line *except* the first.
  my $users_pad = $self->Pad();
  $self->Pad("");

  my ($dd_result, $our_result);
  my ($sAt, $sQ) = ($@, $?);
  { my $dd_warning = "";
    { local $SIG{__WARN__} = sub{ $dd_warning .= $_[0] };
      eval{ $dd_result = $self->dd->Dump };
    }
    if ($dd_warning || $@) {
      warn "Data::Dumper complained:\n$dd_warning\n$@" if $debug;
      ($@, $?) = ($sAt, $sQ);
      $self->dd->Values([$original]);
      $our_result = $self->dd->Dump;
    }
  }
  ($@, $?) = ($sAt, $sQ);
  $self->Pad($users_pad);

  $our_result //= $self->_postprocess_DD_result($dd_result, $original);

  &_RestorePunct;
  $our_result;
}

#---------------------------------------------------------------------
# methods called from Data::Visitor when transforming the input


sub visit_value {
  my $self = shift;
  say "!V value ",_dbravis2(@_) if $debug;
  my $item = shift;
  # N.B. Not called for hash keys (short-circuited in visit_hash_key)

  return $item
    if !defined($item) or reftype($item);  # undef or some kind of ref

  # Prepend a "magic prefix" (later removed) to items which Data::Dumper is
  # likely to represent wrongly or anyway not how we want:
  #
  #  1. Scalars set to strings like "6" will come out as a number 6 rather
  #     than "6" with Useqq(1) or Useperl(1) (string-ness is preserved
  #     with other options).  IMO this is a Data::Dumper bug which the
  #     maintainers won't fix it because the difference isn't functionally
  #     relevant to correctly-written Perl code.  However we want to help
  #     humans debug their software by showing the representation they
  #     most likely used to create the datum.
  #
  #  2. Floating point values come out as "strings" to avoid some
  #     cross-platform issue.  For our purposes we want all numbers
  #     to appear unquoted.
  #
  if (looks_like_number($item) && $item !~ /^0\d/) {
    my $prefix = _show_as_number($item) ? $magic_noquotes_pfx
                                        : $magic_keepquotes_pfx ;
    $item = $prefix.$item;
btw '@@@repl prefixed item:',$item if $debug;
  }

  # Truncacte overly-long strings
  elsif ($maxstringwidth && !_show_as_number($item)
         && length($item) > $maxstringwidth + length($truncsuffix)) {
btw '@@@repl truncating ',substr($item,0,10),"..." if $debug;
    $item = "".substr($item,0,$maxstringwidth).$truncsuffix;
  }
  $item
}#visit_value

sub visit_hash_key {
  my ($self, $item) = @_;
  say "!V visit_hash_key ",_dbravis2($item) if $debug;
  return $item; # don't truncate or otherwise munge
}

sub _prefix_addrvis($$) {
  my ($item, $original) = @_;
  # Called only if enabled (by _Vistype containint 'r').
  #
  # Prefix (the formatted representation of) a ref with it's type 
  # and abbreviated address.  This is done by wrapping the ref in
  # a temporary [array] with the addrvis result, and unwrapping the
  # Data::Dumper result in _postprocess_DD_result().
  $item = [ $magic_addrvis.addrvis($original), $item, $magic_elide_next, ];
  btw '@@@addrvis prefixed item:',_dbvis2($item) if $debug;
  $item
}

sub visit_object {
  my $self = shift;
  say "!V object ",_dbravis2(@_) if $debug;
  my $item = shift;
  my $original = $item;
  my $overload_depth;
  CHECK: {
    if (my $class = blessed($item)) {
      my $enabled;
      OSPEC:
      foreach my $ospec (@$objects) {
        if (ref($ospec) eq "Regexp") {
          my @stack = ($class);
          my %seen;
          while (my $c = shift @stack) {
            $enabled=1, last OSPEC if $c =~ $ospec;
            last CHECK if $seen{$c}++; # circular ISAs !
            no strict 'refs';
            push @stack, @{"${c}::ISA"};
          }
        } else {
          $enabled=1, last OSPEC if ($ospec eq "1" || $item->isa($ospec));
        }
      }
      last CHECK
        unless $enabled;
      if (overload::Overloaded($item)) {
btw '@@@repl overloaded ',"\'$class\'" if $debug;
        # N.B. Overloaded(...) also returns true if it's a NAME of an
        # overloaded package; should not happen in this case.
        warn("Recursive overloads on $item ?\n"),last
          if $overload_depth++ > 10;
        # Stringify objects which have the stringification operator
        if (overload::Method($class,'""')) {
          my $prefix = _show_as_number($item) ? $magic_noquotes_pfx : "";
btw '@@@repl prefix="',$prefix,'"' if $debug;
          $item = $item.""; # stringify;
          if ($item !~ /^${class}=REF/) {
            $item = "${prefix}($class)$item";
          } else {
            # The "stringification" looks like Perl's default; don't prefix it
          }
btw '@@@repl stringified:',$item if $debug;
          redo CHECK;
        }
        # Substitute the virtual value behind an overloaded deref operator
        if (overload::Method($class,'@{}')) {
btw '@@@repl (overload...)' if $debug;
          $item = \@{ $item };
          redo CHECK
        }
        if (overload::Method($class,'%{}')) {
btw '@@@repl (overload...)' if $debug;
          $item = \%{ $item };
          redo CHECK;
        }
        if (overload::Method($class,'${}')) {
btw '@@@repl (overload...)' if $debug;
          $item = \${ $item };
          redo CHECK;
        }
        if (overload::Method($class,'&{}')) {
btw '@@@repl (overload...)' if $debug;
          $item = \&{ $item };
          redo CHECK;
        }
        if (overload::Method($class,'*{}')) {
btw '@@@repl (overload...)' if $debug;
          $item = \*{ $item };
          redo CHECK;
        }
      }
      # No overloaded operator (that we care about); always use addrvis(obj)
      # except for refs to a regex which Data::Dumper formats nicely by itself.
      unless ($class eq 'Regexp') {
btw '@@@repl (no overload repl, not Regexp)' if $debug;
        #$item = "$item";  # will show with "quotes"
        #$item = ${magic_noquotes_pfx}.$item; # omit "quotes"
        $item = ${magic_noquotes_pfx}.addrvis($item);
      }
    }
  }#CHECK
  $item = _prefix_addrvis($item, $original) if index($vistype,"r") >= 0;
  $item
}#visit_object

sub visit_ref {
  my ($self, $item) = @_;
  say "!V ref  ref()=",ref($item)," item=",_dbravis2($item) if $debug;
  my $original = $item;
  # First descend into the structure, probably returning a clone
  $item = $self->SUPER::visit_ref($item);
  # If the ref wasn't replaced by a non-ref, prefix it with the
  # original address if requested.
  $item = _prefix_addrvis($item, $original) if index($vistype,"r") >= 0;
  $item
}

sub visit_glob {
  my ($self, $item) = @_;
  say "!V glob ref()=",ref($item)," item=",_dbravis2($item) if $debug;
  # By default Data::Visitor will create a new anon glob in the output tree.
  # Instead, put the original into the output so the user can recognize
  # it e.g. "*main::STDOUT" instead of an anonymous from Symbol::gensym
  return $item
}

# This was not as good as allowing DD to put in a $VAR1 expression
# Instead, we need to do something to break cycles in the clone to avoid
# a memory leak!
#sub visit_seen {
#  my ($self, $data, $first_result) = @_;
#  #say "!V seen ",_dbravis2(@_) if $debug;
#  say "!V seen ",_dbravis2($first_result) if $debug; ###
#  # Replace circular reference with original ITEM<address>
#  $magic_noquotes_pfx.addrvis($data)
#}

#---------------------------------------------------------------------
sub _preprocess { # Modify the cloned data
  no warnings 'recursion';
  my ($self, $cloned_itemref, $orig_itemref) = @_;
  my ($debug, $seenhash) = @$self{qw/Debug Seenhash/};

btw '##pp AAA cloned=",addrvis($cloned_itemref)," -> ',_dbvis($$cloned_itemref) if $debug;
btw '##         orig=",addrvis($orig_itemref)," -> ",_dbvis($$orig_itemref)' if $debug;

  # Pop back if this item was visited previously
  if ($seenhash->{ refaddr($cloned_itemref) }++) {
    btw '     Seen already' if $debug;
    return
  }

  # About TIED VARIABLES:
  # We must never modify a tied variable because of user-defined side-effects.
  # So when we want to replace a tied variable we untie it first, if possible.
  # N.B. The whole structure was cloned, so this does not untie the
  # user's variables.
  #
  # All modifications (untie and over-writing) is done in eval{...} in case
  # the data is read-only or an UNTIE handler throws -- in which case we leave
  # the cloned item as it is.  This occurs e.g. with the 'Readonly' module;
  # I tried using Readonly::Clone (insterad of Clone::clone) to copy the input,
  # since it is supposed to make a mutable copy; but it has bugs with refs to
  # other refs, and doesn't actually make everything mutable; it was a big mess
  # so now taking the simple way out.

    # Side note: Taking a ref to a member of a tied container,
    # e.g. \$tiedhash{key}, actually returns an overloaded object or some other
    # magical thing which, every time it is de-referenced, FETCHes the datum
    # into a temporary.
    #
    # There is a bug somewhere which makes it unsafe to store these fake
    # references inside tied variables because after the variable is 'untie'd
    # bad things can happen (refcount problems?).   So after a lot of mucking
    # around I gave up trying to do anything intelligent about tied data.
    # I still have to untie variables before over-writing them with substitute
    # content.

  # Note: Our Item is only ever a scalar, either the top-level item from the
  # user or a member of a container we unroll below.  In either case the
  # scalar could be either a ref to something or a non-ref value.

  eval {
    if (tied($$cloned_itemref)) {
      btw '     Item itself is tied' if $debug;
      my $copy = $$cloned_itemref;
      untie $$cloned_itemref;
      $$cloned_itemref = $copy; # n.b. $copy might be a ref to a tied variable
      oops if tied($$cloned_itemref);
    }

    my $rt = reftype($$cloned_itemref) // ""; # "" if item is not a ref
    if (reftype($cloned_itemref) eq "SCALAR") {
      oops if $rt;
      btw '##pp item is non-ref scalar; stop.' if $debug;
      return
    }

    # Item is some kind of ref
    oops unless reftype($cloned_itemref) eq "REF";
    oops unless reftype($orig_itemref) eq "REF";

    if ($rt eq "SCALAR" || $rt eq "LVALUE" || $rt eq "REF") {
      btw '##pp dereferencing ref-to-scalarish $rt' if $debug;
      $self->_preprocess($$cloned_itemref, $$orig_itemref);
    }
    elsif ($rt eq "ARRAY") {
      btw '##pp ARRAY ref' if $debug;
      if (tied @$$cloned_itemref) {
        btw '     aref to *tied* ARRAY' if $debug;
        my $copy = [ @$$cloned_itemref ]; # only 1 level
        untie @$$cloned_itemref;
        @$$cloned_itemref = @$copy;
      }
      for my $ix (0..$#{$$cloned_itemref}) {
        $self->_preprocess(\$$cloned_itemref->[$ix], \$$orig_itemref->[$ix]);
      }
    }
    elsif ($rt eq "HASH") {
  btw '##pp HASH ref' if $debug;
      if (tied %$$cloned_itemref) {
        btw '     href to *tied* HASH' if $debug;
        my $copy = { %$$cloned_itemref }; # only 1 level
        untie %$$cloned_itemref;
        %$$cloned_itemref = %$copy;
        die if tied %$$cloned_itemref;
      }
      #For easier debugging, do in sorted order
      btw '   #### iterating hash values...' if $debug;
      for my $key (sort keys %$$cloned_itemref) {
        $self->_preprocess(\$$cloned_itemref->{$key}, \$$orig_itemref->{$key});
      }
    }
  };#eval
  if ($@) {
    btw "*EXCEPTION*, just returning\n$@\n" if $debug;
  }
}

sub _show_as_number(_) {
  my $value = shift;

  # IMPORTANT: We must not do any numeric ops or comparisions
  # on $value because that may set some magic which defeats our attempt
  # to try bitstring unary & below (after a numeric compare, $value is
  # apparently assumed to be numeric or dual-valued even if it
  # is/was just a "string").

  return 0 if !defined $value;

  # if the utf8 flag is on, it almost certainly started as a string
  return 0 if (ref($value) eq "") && utf8::is_utf8($value);

  # There was a Perl bug where looks_like_number() provoked a warning from
  # BigRat.pm if it is called under 'use bigrat;' so we must not do that.
  #   https://github.com/Perl/perl5/issues/20685
  #return 0 unless looks_like_number($value);

  # JSON::PP uses these tricks:
  # string & "" -> ""  # bitstring AND, truncating to shortest operand
  # number & "" -> 0 (with warning)
  # number * 0 -> 0 unless number is nan or inf

  # Attempt uniary & with "string" and see what happens
  my $uand_str_result = eval {
    use warnings "FATAL" => "all"; # Convert warnings into exceptions
    # 'bitwise' is the default only in newer perls. So disable.
    BEGIN {
      eval { # "no feature 'bitwise'" won't compile on Perl 5.20
        feature->unimport( 'bitwise' );
        warnings->unimport("experimental::bitwise");
      };
      $@ = "";
    }
    no warnings "once";
    # Use FF... so we can see what $value was in debug messages below
    my $dummy = ($value & "\x{FF}\x{FF}\x{FF}\x{FF}\x{FF}\x{FF}\x{FF}\x{FF}");
  };
  btw '##_san $value \$@=$@' if $Debug;
  if ($@) {
    if ($@ =~ /".*" isn't numeric/) {
      return 1; # Ergo $value must be numeric
    }
    if ($@ =~ /\& not supported/) {
      # If it is an object then it probably (but not necessarily)
      # is numeric but just doesn't support bitwise operators,
      # for example BigRat.
      return 1 if defined blessed($value);
    }
    if ($@ =~ /no method found/) { # overloaded but does not do '&'
      # It must use overloads, but does not implement '&'
      # Assume it is string-ish
      return 0 if defined blessed($value); # else our mistake, isn't overloaded
    }
    warn "# ".__PACKAGE__." : value=",_dbshow($value),
         "\n    Unhandled warn/exception from unary & :$@\n"
      if $Debug;
    # Unknown problem, treat as a string
    return 0;
  }
  elsif (ref($uand_str_result) ne "" && $uand_str_result =~ /NaN|Inf/) {
    # unary & returned an object representing Nan or Inf
    # (e.g. Math::BigFloat) so $value must be numberish.
    return 1;
  }
  warn "# ".__PACKAGE__." : (value & \"...\") succeeded\n",
       "    value=", _dbshow($value), "\n",
       "    uand_str_result=", _dbvis($uand_str_result),"\n"
    if $Debug;
  # Sigh.  With Perl 5.32 (at least) $value & "..." stringifies $value
  # or so it seems.
  if (blessed($value)) {
    # +42 might throw if object is not numberish e.g. a DateTime
    if (blessed(eval{ $value + 42 })) {
      warn "    Object and value+42 is still an object, so probably numberish\n"
        if $Debug;
      return 1
    } else {
      warn "    Object and value+42 is NOT an object, so it must be stringish\n"
        if $Debug;
      return 0
    }
  } else {
    warn "    NOT an object, so must be a string\n",
      if $Debug;
    return 0;
  }
}

# Split keys into "components" (e.g. 2_16.A has 3 components) and sort
# components containing only digits numerically.
sub __sortkeys {
  my $hash = shift;
  my $r = [
    sort { my @a = split /(?<=\d)(?=\D)|(?<=\D)(?=\d)/,$a;
           my @b = split /(?<=\d)(?=\D)|(?<=\D)(?=\d)/,$b;
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
  ];
  $r
}

my $balanced_re = RE_balanced(-parens=>'{}[]()');

# cf man perldata
my $userident_re = qr/ (?: (?=\p{Word})\p{XID_Start} | _ )
                           (?: (?=\p{Word})\p{XID_Continue}  )* /x;

my $pkgname_re = qr/ ${userident_re} (?: :: ${userident_re} )* /x;

our $curlies_re = RE_balanced(-parens=>'{}');
our $parens_re = RE_balanced(-parens=>'()');
our $curliesorsquares_re = RE_balanced(-parens=>'{}[]');

my $anyvname_re =
  qr/ ${pkgname_re} | [0-9]+ | \^[A-Z]
                    | [-+!\$\&\;i"'().,\@\/:<>?\[\]\~\^\\] /x;

my $anyvname_or_refexpr_re = qr/ ${anyvname_re} | ${curlies_re} /x;

sub __unmagic_atom() {  # edits $_
  s/(['"])([^'"]*?)
    (?:\Q$magic_noquotes_pfx\E)
    (.*?)(\1)/$2$3/xgs;

  s/\Q$magic_keepquotes_pfx\E//gs;
}

sub __unesc_unicode() {  # edits $_
  if (/^"/) {
    # Data::Dumper with Useqq(1) outputs wide characters as hex escapes
    # Note that a BOM is the ZERO WIDTH NO-BREAK SPACE character and
    # so is considered "Graphical", but we want to see it as hex rather
    # than "", and probably any other "Format" category Unicode characters.

    s/
       \G (?: [^\\]++ | \\[^x] )*+ \K (?<w> \\x\x{7B} (?<hex>[a-fA-F0-9]+) \x{7D} )
     /
       my $orig = $+{w};
       local $_ = hex( length($+{hex}) > 6 ? '0' : $+{hex} );
       $_ = $_ > 0x10FFFF ? "\0" : chr($_); # 10FFFF is Unicode limit
       # Using 'lc' so regression tests do not depend on Data::Dumper's
       # choice of case when escaping wide characters.
       (m<\P{XPosixGraph}|[\0-\177]>
          || m<\p{General_Category=Format}>) ? lc($orig) : $_
     /xesg;
  }
}

sub __change_quotechars($) {  # edits $_
  if (s/^"//) {
    oops unless s/"$//;
    s/\\"/"/g;
    my ($l, $r) = split //, $_[0]; oops unless $r;
    s/([\Q$l$r\E])/\\$1/g;
    $_ = "qq".$l.$_.$r;
  }
}

my %qqesc2controlpic = (
  '\0' => "\N{SYMBOL FOR NULL}",
  '\a' => "\N{SYMBOL FOR BELL}",
  '\b' => "\N{SYMBOL FOR BACKSPACE}",
  '\e' => "\N{SYMBOL FOR ESCAPE}",
  '\f' => "\N{SYMBOL FOR FORM FEED}",
  '\n' => "\N{SYMBOL FOR NEWLINE}",
  '\r' => "\N{SYMBOL FOR CARRIAGE RETURN}",
  '\t' => "\N{SYMBOL FOR HORIZONTAL TABULATION}",
);
sub __subst_controlpics() {  # edits $_
  if (/^"/) {
    s{ \G (?: [^\\]++ | \\[^0abefnrt] )*+ \K ( \\[abefnrt] | \\0(?![0-7]) )
     }{
        $qqesc2controlpic{$1} // $1
      }xesg;
  }
}
sub __subst_spacedots() {  # edits $_
  if (/^"/) {
    s{\N{MIDDLE DOT}}{\N{BLACK LARGE CIRCLE}}g;
    s{ }{\N{MIDDLE DOT}}g;
  }
}

my $indent_unit;

sub _mycallloc(;@) {
  my ($lno, $subcalled) = (caller(1))[2,3];
  ":".$lno.(@_ ? _dbavis(@_) : "")." "
}

use constant {
  _WRAP_ALWAYS  => 1,
  _WRAP_ALLHASH => 2,
};
use constant _WRAP_STYLE => (_WRAP_ALLHASH);

sub _postprocess_DD_result {
  (my $self, local $_, my $original) = @_;
  no warnings 'recursion';
  my ($debug, $vistype, $foldwidth, $foldwidth1)
    = @$self{qw/Debug _Vistype Foldwidth Foldwidth1/};
  my $useqq = $self->Useqq();
  my $unesc_unicode = $useqq =~ /utf|unic/;
  my $controlpics   = $useqq =~ /pic/;
  my $spacedots     = $useqq =~ /space/;
  my $qq            = $useqq =~ /qq(?:=(..))?/ ? ($1//'{}') : '';
  my $pad = $self->Pad() // "";

  $indent_unit = 2; # make configurable?

  if ($debug) {
    our $_dbmaxlen = INT_MAX;
    btw '##RAW DD result: ',_dbrawstr($_);
  }

  my $top = { tlen => 0, children => [] };
  my $context = $top;
  my $prepending = "";

  my sub atom($;$) {
    (local $_, my $mode) = @_;
    $mode //= "";

    __unmagic_atom ;
    __unesc_unicode          if $unesc_unicode;
    __subst_controlpics      if $controlpics;
    __subst_spacedots        if $spacedots;
    __change_quotechars($qq) if $qq;

    if ($prepending) { $_ = $prepending . $_; $prepending = ""; }

    btw "###atom",_mycallloc(), _dbrawstr($_),"($mode)"
      ,"\n context:",_dbvisnew($context)->Sortkeys(sub{[grep{exists $_[0]->{$_}} qw/O C tlen children CLOSE_AFTER_NEXT/]})->Dump()
      if $debug;
    if ($mode eq "prepend_to_next") {
      $prepending .= $_;
    } else {
      if ($mode eq "") {
        push @{ $context->{children} }, $_;
      }
      elsif ($mode eq "open") {
        my $child = {
          O => $_,
          tlen => 0,
          children => [],
          C => undef,
          parent => $context,
        };
        weaken( $child->{parent} );
        push @{ $context->{children} }, $child;
        $context = $child;
      }
      elsif ($mode eq "close") {
        oops if defined($context->{C});
        $context->{C} = $_;
        $context->{tlen} += length($_);
        $context = $context->{parent}; # undef if closing the top item
      }
      elsif ($mode eq "append_to_prev") {
        my $prev = $context;
        { #block for 'redo'
          oops unless @{$prev->{children}} > 0;
          if (ref($prev->{children}->[-1] // oops("No previous!"))) {
            $prev = $prev->{children}->[-1];
            if (! $prev->{C}) { # empty or not-yet-read closer?
              redo; # ***
            }
            $prev->{C} .= $_;
          } else {
            $prev->{children}->[-1] .= $_;
          }
        }
      }
      else {
        oops "mode=",_dbvis($mode);
      }
      my $c = $context;
      while(defined $c) {
        $c->{tlen} += length($_);
        $c = $c->{parent};
      }
      if ($context->{CLOSE_AFTER_NEXT}) {
        oops(_dbvis($context)) if defined($context->{C});
        $context->{C} = "";
        $context = $context->{parent};
      }
    }
  }#atom

  my sub equal_greater($) {  # =>
    my $lhs = $context->{children}->[-1] // oops;
    oops if ref($lhs);
    my $newchild = {
      O => "",
      tlen => length($lhs),
      children => [ $lhs ],
      C => undef,
      parent => $context,
    };
    weaken($newchild->{parent});
    $context->{children}->[-1] = $newchild;
    $context = $newchild;
    atom($_[0]); # the " => "
    oops unless $context == $newchild;
    $context->{CLOSE_AFTER_NEXT} = 1;
  }

  # There is a trade-off between compactness (e.g. want a single line when
  # possible), and ease of reading large structures.
  #
  # At any nesting level, if everything (including any nested levels) fits
  # on a single line, then that part is output without folding;
  #
  # 4/25/2023: Added the (non-public) config constant _WRAP_STYLE;
  #
  # (_WRAP_STYLE == _WRAP_ALWAYS):
  # If folding is necessary, then *every* member of the folded block
  # appears on a separate line, so members all vertically align.
  #
  # (_WRAP_STYLE & _WRAP_ALLHASH): Members of a hash (key => value)
  # are shown on separate lines, but not members of an array.
  #
  # Otherwise:
  #
  # When folding is necessary, every member appears on a separate
  # line if ANY of them will not fit on a single line; however if
  # they all fit individually, then shorter members will be run
  # together on the same line.  For example:
  #
  #    [aaa,bbb,[ccc,ddd,[eee,fff,hhhhhhhhhhhhhhhhhhhhh,{key => value}]]]
  #
  # might be shown as
  #    [ aaa,bbb,  # N.B. space inserted before aaa to line up with next level
  #      [ ccc,ddd,  # packed because all siblings fit individually
  #        [eee,fff,hhhhhhhhhhhhhhhhhhhhh,{key => value}] # entirely fits
  #      ]
  #    ]
  # but if Foldwidth is smaller then like this:
  #    [ aaa,bbb,
  #      [ ccc,  # sibs vertically-aligned because not all of them fit
  #        ddd,
  #        [ eee,fff,  # but within this level, all siblings fit
  #          hhhhhhhhhhhhhhhhhhhhh,
  #          {key => value}
  #        ]
  #      ]
  #    ]
  # or if Foldwidth is very small then:
  #    [ aaa,
  #      bbb,
  #      [ ccc,
  #        ddd,
  #        [ eee,
  #          fff,
  #          hhhhhhhhhhhhhhhhhhhhh,
  #          { key
  #            =>
  #            value
  #          }
  #        ]
  #      ]
  #    ]
  #
  # Note: Indentation is done regardless of Foldwidth, so deeply nested
  # structures may extend beyond Foldwidth even if all elements are short.

  my $foldwidthN = $foldwidth || INT_MAX;
  my $maxlinelen = $foldwidth1 || $foldwidthN;
  $foldwidthN -= length($pad);
  $maxlinelen -= length($pad);

  my $outstr;
  my $linelen;
  our $level;
  my sub expand_children($) {
    my $parent = shift;
    # $level is already set appropriately for $parent->{children},
    # and the parent's {opener} is at the end of $outstr.
    #
    # Intially we are called with a fake parent ($top) containing
    # no {opener} and the top-most item as its only child, with $level==0;
    # this puts the top item at the left margin.
    #
    # If all children individually fit then run them all together,
    # wrapping only between siblings; otherwise start each sibling on
    # it's own line so they line up vertically.
    # [4/25/2023: Now controlled by _WRAP_STYLE]

    my $available = $maxlinelen - $linelen;
    my $indent_width = $level * $indent_unit;

    my $run_together =
      (_WRAP_STYLE & _WRAP_ALWAYS)==0
      &&
      all{ (ref() ? $_->{tlen} : length) <= $available } @{$parent->{children}}
      ;

    if (!$run_together
        && @{$parent->{children}}==3
        && !ref(my $item=$parent->{children}->[1])) {
      # Concatenate (key,=>) if possible
      if ($item =~ /\A *=> *\z/) {
        $run_together = 1;
        btw "#     (level $level): Running together $parent->{children}->[0] => value" if $debug;
      }
    }

    my $indent = ' ' x $indent_width;

    btw "###expand",_mycallloc(), "level $level, avail=$available",
        " rt=",_tf($run_together),
        " indw=$indent_width ll=$linelen maxll=$maxlinelen : ",
        #"{ tlen=",$parent->{tlen}," }",
        " p=",_dbvisnew($parent)->Sortkeys(sub{[grep{exists $_[0]->{$_}} qw/O C tlen CLOSE_AFTER_NEXT/]})->Dump(),
        "\n  os=",_dbstr($outstr) if $debug;

    #oops(_dbavis($linelen,$indent_width)) unless $linelen >= $indent_width;

    my $first = 1;
    for my $child (@{$parent->{children}}) {
      my $child_len = ref($child) ? $child->{tlen} : length($child);
      my $fits = ($child_len <= $available) || 0;

      if ($first) {
      } else {
        if(!$fits && !ref($child)) {
          if ($child =~ /( +)\z/ && ($child_len-length($1)) <= $available) {
            # remove trailing space(s) e.g. in ' => '
            substr($child,-length($1),INT_MAX,"");
            $child_len -= length($1);
            oops unless $child_len <= $available;
            $fits = 2;
            btw "#     (level $level): Chopped ",_dbstr($1)," from child" if $debug;
          }
          if (!$fits && $linelen <= $indent_width && $run_together) {
            # If we wrap we'll end up at the same or worse position after
            # indenting, so don't bother wrapping if running together
            $fits = 3;
            btw "#     (level $level): Wrap would not help" if $debug
          }
        }
        if (!$fits || !$run_together) {
          # start a second+ line
          $outstr =~ s/ +\z//;
          $outstr .= "\n$indent";
          $linelen = $indent_width;

          # elide any initial spaces after wrapping, e.g. in " => "
          $child =~ s/^ +// unless ref($child);

          $available = $maxlinelen - $linelen;
          $child_len = ref($child) ? $child->{tlen} : length($child);
          $fits = ($child_len <= $available);
          btw "#     (level $level): 2nd+ Pre-WRAP; ",_dbstr($child)," cl=$child_len av=$available ll=$linelen f=$fits rt=",_tf($run_together)," os=",_dbstr($outstr) if $debug;
        } else {
          btw "#     (level $level): (no 2nd+ pre-wrap); ",_dbstr($child)," cl=$child_len av=$available ll=$linelen f=$fits rt=",_tf($run_together) if $debug;
        }
      }

      if (ref($child)) {
        ++$level;
        $outstr .= $child->{O};
        $linelen += length($child->{O});
        if (! $fits && $child->{O} ne "") {
          # Wrap before first child, if there is a real opener (not for '=>')
          $outstr =~ s/ +\z//;
          $outstr .= "\n$indent" . (' ' x $indent_unit);
          $linelen = $indent_width + $indent_unit;
          btw "#     (l $level): Wrap after opener: os=",_dbstr($outstr) if $debug;
        }
        __SUB__->($child);
        if (! $fits && $child->{O} ne "") {
          # Wrap before closer if we wrapped after opener
          $outstr =~ s/ +\z//;
          $outstr .= "\n$indent";
          $linelen = $indent_width;
          btw "#     (l $level): Wrap after closer; ll=$linelen os=",_dbstr($outstr) if $debug;
        }
        $outstr .= $child->{C};
        $linelen += length($child->{C});
        --$level;
      } else {
        $outstr .= $child;
        $linelen += length($child);
        btw "#     (level $level): appended SCALAR ",_dbstr($child)," os=",_dbstr($outstr) if $debug;
      }
      $available = $maxlinelen - $linelen;
      $first = 0;
    }
  }#expand_children

  # Remove the magic wrapper created by _prefix_addrvis().  The original $ref 
  # was replaced by 
  #
  #    [ $magic_addrvis.addrvis($ref), $ref, $magic_elide_next, ];
  #
  # Data::Dumper formatted the magic* items as "quoted strings"
  #
  s/\[\s*(["'])\Q$magic_addrvis\E(.*?)\1,\s*/$2/gs;
  s/,\s*(["'])\Q$magic_elide_next\E\1,?\s*\]//gs
    && $debug && btw "Unwrapped addrvis:",_dbvis($_);

  while ((pos()//0) < length) {
       if (/\G[\\\*\!]/gc)                       { atom($&, "prepend_to_next") }
    elsif (/\G[,;]/gc)                           { atom($&, "append_to_prev") }
    elsif (/\G"(?:[^"\\]++|\\.)*+"/gsc)          { atom($&) } # "quoted"
    elsif (/\G'(?:[^'\\]++|\\.)*+'/gsc)          { atom($&) } # 'quoted'
    elsif (m(\Gqr/(?:[^\\\/]++|\\.)*+/[a-z]*)gsc){ atom($&) } # Regexp
    elsif (/\G[A-Za-z][:\w]*\<\d+:[\da-fA-F]+\>/gsc) { 
      # addrvis() result e.g. My::Package<decimal:hex>
      atom($&, "prepend_to_next");
    }

    # With Deparse(1) the body has arbitrary Perl code, which we can't parse
    elsif (/\Gsub\s*${curlies_re}/gc)            { atom($&) } # sub{...}

    # $VAR1->[ix] $VAR1->{key} or just $varname
    elsif (/\G(?:my\s+)?\$(?:${userident_re}|\s*->\s*|${balanced_re}+)++/gsc) { atom($&) }

    elsif (/\G\b[A-Za-z_][A-Za-z0-9_]*+\b/gc) { atom($&) } # bareword?
    elsif (/\G-?\d[\deE\.]*+\b/gc)            { atom($&) } # number
    elsif (/\G\s*=>\s*/gc)                    { equal_greater($&) }
    elsif (/\G\s*=(?=[\w\s'"])\s*/gc)         { atom($&) }
    elsif (/\G:*${pkgname_re}/gc)             { atom($&) }
    elsif (/\G[\[\{\(]/gc)                    { atom($&, "open") }
    elsif (/\G[\]\}\)]/gc)                    { atom($&, "close") }
    elsif (/\G\s+/sgc)                        {          }
    else {
      my $remnant = substr($_,pos//0);
      Carp::cluck "UNPARSED ",_dbstr(substr($remnant,0,30)."..."),"  ",_dbstrposn($_,pos()//0),"\nFULL STRING:",_dbstr($_),"\n(Using remainder as-is)\n" ;
      atom($remnant);
      while (defined $context->{parent}) { atom("", "close"); }
      last;
    }
  }
  oops "Dangling prepend ",_dbstr($prepending) if $prepending;

  btw "--------top-------\n",_dbvisnew($top)->Sortkeys(sub{[qw/O C tlen children/]})->Dump,"\n-----------------" if $debug;

  $outstr = "";
  $linelen = 0;
  $level = 0;
  expand_children($top);

  if (index($vistype,'a') >= 0) {
    # show [...] as (val1,val2,...) array initializer
    $outstr =~ s/\A\[/(/ && $outstr =~ s/\]\z/)/s or oops;
  }
  elsif (index($vistype,'h') >= 0) {
    # show {...} as (key => val, ...) hash initializer
    $outstr =~ s/\A\{/(/ && $outstr =~ s/\}\z/)/s or oops;
  }
  elsif (index($vistype,'l') >= 0) {
    # show as a bare list without brackets
    $outstr =~ s/\A[\[\{]// && $outstr =~ s/[\]\}]\z//s or oops;
  }

  # Insert user-specified padding after each embedded newline
  if ($pad) {
    $outstr =~ s/\n\K(?=[^\n])/$pad/g;
  }

  $outstr
} #_postprocess_DD_result {

sub _Interpolate {
  my ($self, $input, $i_or_d) = @_;
  return "<undef arg>" if ! defined $input;

  &_SaveAndResetPunct;

  my $debug = $self->Debug;
  my $useqq = $self->Useqq;

  my $q = $useqq ? "" : "q";
  my $funcname = $i_or_d . "vis" .$q;

  my @pieces;  # list of [visfuncname or 'p' or 'e', inputstring]
  { local $_ = $input;
    if (/\b((?:ARRAY|HASH)\(0x[a-fA-F0-9]+\))/) {
      state $warned=0;
      carp("Warning: String passed to $funcname may have been interpolated by Perl\n(use 'single quotes' to avoid this)\n") unless $warned++;
    }
    while (
      /\G (
           # Stuff without variable references (might include \n etc. escapes)

           #This gets "recursion limit exceeded"
           #( (?: [^\\\$\@\%] | \\[^\$\@\%] )++ )
           #|

           (?: [^\\\$\@\%]++ )
           |
           #(?: (?: \\[^\$\@\%] )++ )
           (?: (?: \\. )++ )
           |

           # $#arrayvar $#$$...refvarname $#{aref expr} $#$$...{ref2ref expr}
           #
           (?: \$\#\$*+\K ${anyvname_or_refexpr_re} )
           |

           # $scalarvar $$$...refvarname ${sref expr} $$$...{ref2ref expr}
           #  followed by [] {} ->[] ->{} ->method() ... «zero or more»
           # EXCEPT $$<punctchar> is parsed as $$ followed by <punctchar>

           (?:
             (?: \$\$++ ${pkgname_re} \K | \$ ${anyvname_or_refexpr_re} \K )
             (?:
               (?: ->\K(?: ${curliesorsquares_re}|${userident_re}${parens_re}? ))
               |
               ${curliesorsquares_re}
             )*
           )
           |

           # @arrayvar @$$...varname @{aref expr} @$$...{ref2ref expr}
           #  followed by [] {} «zero or one»
           #
           (?: \@\$*+\K ${anyvname_or_refexpr_re} ${$curliesorsquares_re}? )
           |
           # %hash %$hrefvar %{href expr} %$$...sref2hrefvar «no follow-ons»
           (?: \%\$*+\K ${anyvname_or_refexpr_re} )
          ) /xsgc)
    {
      local $_ = $1; oops unless length() > 0;
      if (/^[\$\@\%]/) {
        my $sigl = substr($_,0,1);
        if ($i_or_d eq 'd') {
          # Inject a "plain text" fragment containing the "expr=" prefix,
          # omitting the '$' sigl if the expr is a plain '$name'.
          push @pieces, ['p', (/^\$(?!_)(${userident_re})\z/ ? $1 : $_)."="];
        }
        if ($sigl eq '$') {
          push @pieces, ["vis", $_];
        }
        elsif ($sigl eq '@') {
          push @pieces, ["avis", $_];
        }
        elsif ($sigl eq '%') {
          push @pieces, ["hvis", $_];
        }
        else { confess "BUG:sigl='$sigl'"; }
      } else {
        if (/^.+?(?<!\\)([\$\@\%])/) { confess __PACKAGE__." bug: Missed '$1' in «$_»" }
        # Due to the need to simplify the big regexp above, \x{abcd} is now
        # split into "\x" and "{abcd}".  Combine consecutive pass-thrus
        # into a single passthru ('p') and convert later to 'e' if
        # an eval if needed.
        if (@pieces && $pieces[-1]->[0] eq 'p') {
          $pieces[-1]->[1] .= $_;
        } else {
          push @pieces, [ 'p', $_ ];
        }
      }
    }
    if (!defined(pos) || pos() < length($_)) {
      my $leftover = substr($_,pos()//0);
      # Try to recognize user syntax errors
      croak "Invalid expression syntax starting at '$leftover' in $funcname arg"
        if $leftover =~ /^[\$\@\%][\s\%\@]/;
      # Otherwise we may have a parser bug
      confess "Invalid expression (or ".__PACKAGE__." bug):\n«$leftover»";
    }
    foreach (@pieces) {
      my ($meth, $str) = @$_;
      next unless $meth eq 'p' && $str =~ /\\[abtnfrexXN0-7]/;
      $str =~ s/([()\$\@\%])/\\$1/g;  # don't hide \-escapes to be interpolated!
      $str =~ s/\$\\/\$\\\\/g;
      $_->[1] = "qq(" . $str . ")";
      $_->[0] = 'e';
    }
  } #local $_

  @_ = ($self, $funcname, \@pieces);
  goto &DB::DB_Vis_Interpolate
}

sub quotekey(_) { # Quote a hash key if not a valid bareword
  $_[0] =~ /\A${userident_re}\z/s ? $_[0] :
            $_[0] =~ /(?!.*')["\$\@]/  ? visq("$_[0]") :
            $_[0] =~ /\W/ && !looks_like_number($_[0]) ? vis("$_[0]") :
            "\"$_[0]\""
}

package
  DB;

sub DB_Vis_Interpolate {
  my ($self, $funcname, $pieces) = @_;
  my $result = "";
  foreach my $p (@$pieces) {
    my ($methname, $arg) = @$p;
    if ($methname eq 'p') {
      $result .= $arg;
    }
    elsif ($methname eq 'e') {
      $result .= DB::DB_Vis_Eval($funcname, $arg);
    } else {
      # Reduce indent before first wrap to account for stuff alrady there
      my $leftwid = length($result) - rindex($result,"\n") - 1;
      my $foldwidth = $self->{Foldwidth};
      local $self->{Foldwidth1} = $self->{Foldwidth1} // $foldwidth;
      if ($foldwidth) {
        $self->{Foldwidth1} -= $leftwid if $leftwid < $self->{Foldwidth1}
      }
      $result .= $self->$methname( DB::DB_Vis_Eval($funcname, $arg) );
    }
  }

  &Data::Dumper::Interp::_RestorePunct;  # saved in _Interpolate
  $result
}# DB_Vis_Interpolate

# eval a string in the user's context and return the result.  The nearest
# non-DB frame must be the original user's call; this is accomplished by
# dvis(), and friends using "goto &_Interpolate", which in turn
# does "goto &DB::DB_Vis_Interpolate" to enter package DB.
sub DB_Vis_Eval($$) {
  my ($label_for_errmsg, $evalarg) = @_;
  Carp::confess("Data::Dumper::Interp bug:empty evalarg") if $evalarg eq "";
  # Inspired perl5db.pl but at this point has been rewritten

  # Find the closest non-DB caller.  The eval will be done in that package.
  # Find the next caller further up which has arguments (i.e. wasn't doing
  # "&subname;"), and make @_ contain those arguments.
  my ($distance, $pkg, $fname, $lno);
  for ($distance = 0 ; ; $distance++) {
    ($pkg, $fname, $lno) = caller($distance);
    last if $pkg ne "DB";
  }
  local *_ = [];
  while() {
    $distance++;
    my ($p, $hasargs) = (caller($distance))[0,4];
    if (! defined $p){
      *_ = [ '<@_ is not defined in the outer block>' ];
      last
    }
    if ($hasargs) {
      *_ = [ @DB::args ];  # copy in case of recursion
      last
    }
  }

  my @result = do {
    local @Data::Dumper::Interp::result;
    local $Data::Dumper::Interp::string_to_eval =
      "package $pkg; "
     .' &Data::Dumper::Interp::_RestorePunct_NoPop;'      # saved in _Interpolate
                  # N.B. eval first clears $@ but this restores $@ inside the eval
     .' @Data::Dumper::Interp::result = '.$evalarg.';'
     .' $Data::Dumper::Interp::save_stack[-1]->[0] = $@;' # possibly changed by a tie handler
     ;
     &DB_Vis_Evalwrapper;
     @Data::Dumper::Interp::result
  };
  my $errmsg = $@;

  if ($errmsg) {
    $errmsg = Data::Dumper::Interp::__chop_loc($errmsg);
    Carp::croak("${label_for_errmsg}: Error interpolating '$evalarg':\n$errmsg\n");
  }

  wantarray ? @result : (do{die "bug" if @result>1}, $result[0])
}# DB_Vis_Eval

1;
 __END__

=pod

=encoding UTF-8

=head1 NAME

Data::Dumper::Interp - interpolate Data::Dumper output into strings for human consumption

=head1 SYNOPSIS

  use open IO => ':locale';
  use Data::Dumper::Interp;

  @ARGV = ('-i', '/file/path');
  my %hash = (abc => [1,2,3,4,5], def => undef);
  my $ref = \%hash;
  my $obj = bless {}, "Foo::Bar";

  # Interpolate variables in strings with Data::Dumper output
  say ivis 'FYI ref is $ref\nThat hash is: %hash\nArgs are @ARGV';

    # -->FYI ref is {abc => [1,2,3,4,5], def => undef}
    #    That hash is: (abc => [1,2,3,4,5], def => undef)
    #    Args are ("-i","/file/path")

  # Label interpolated values with "expr="
  say dvis '$ref\nand @ARGV';

    # -->ref={abc => [1,2,3,4,5], def => undef}
    #    and @ARGV=("-i","/file/path")

  # Functions to format one thing
  say vis $ref;      #prints {abc => [1,2,3,4,5], def => undef}
  say vis \@ARGV;    #prints ["-i", "/file/path"]  # any scalar
  say avis @ARGV;    #prints ("-i", "/file/path")
  say hvis %hash;    #prints (abc => [1,2,3,4,5], def => undef)

  # Format a reference with abbreviated referent address
  say rvis $href;    #prints HASH<457:1c9>{abc => [1,2,3,4,5], ...}

  # Just abbreviate a referent address or arbitrary number
  say addrvis refaddr($ref);  # 457:1c9
  say addrvis $ref;           # HASH<457:1c9>
  say addrvis $obj;           # Foo::Bar<984:ef8>

  # Stringify objects
  { use bigint;
    my $struct = { debt => 999_999_999_999_999_999.02 };
    say vis $struct;
      # --> {debt => (Math::BigFloat)999999999999999999.02}

    # But if you do want to see object internals
    say visnew->Objects(0)->vis($struct);
    { local $Data::Dumper::Interp::Objects=0; say vis $struct; } #another way
      # --> {debt => bless({...lots of stuff...},'Math::BigInt')}
  }

  # Wide characters are readable
  use utf8;
  my $h = {msg => "My language is not ASCII ☻ ☺ 😊 \N{U+2757}!"};
  say dvis '$h' ;
    # --> h={msg => "My language is not ASCII ☻ ☺ 😊 ❗"}

  #-------- OO API --------

  say Data::Dumper::Interp->new()
            ->MaxStringwidth(50)->Maxdepth($levels)->vis($datum);

  say visnew->MaxStringwidth(50)->Maxdepth($levels)->vis($datum);

  #-------- UTILITY FUNCTIONS --------
  say u($might_be_undef);  # $_[0] // "undef"
  say quotekey($string);   # quote hash key if not a valid bareword
  say qsh($string);        # quote if needed for /bin/sh
  say qshpath($pathname);  # shell quote excepting ~ or ~username prefix
  say "Runing this: ", qshlist(@command_and_args);

    system "ls -ld ".join(" ",map{ qshpath }
                              ("/tmp", "~sally/My Documents", "~"));


=head1 DESCRIPTION

This Data::Dumper wrapper optimizes output for human consumption
and avoids side-effects which interfere with debugging.

The namesake feature is interpolating Data::Dumper output
into strings, but simple functions are also provided
to show a scalar, array, or hash.

Internally, Data::Dumper is called to visualize (i.e. format) data
with pre- and post-processing to "improve" the results:

=over 2

=item * Output is compact (1 line if possible,
otherwise folded at your terminal width), WITHOUT a trailing newline.

=item * Printable Unicode characters appear as themselves.

=item * Object internals are not shown; Math:BigInt etc. are stringified.

=item * "virtual" values behind overloaded deref operators are shown.

=item * Data::Dumper bugs^H^H^H^Hquirks are circumvented.

=back

See "DIFFERENCES FROM Data::Dumper".

Finally, a few utilities are provided to quote strings for /bin/sh.

=head1 FUNCTIONS

=head2 ivis 'string to be interpolated'

Returns the argument with variable references and escapes interpolated
as in in Perl double-quotish strings, but using Data::Dumper to
format variable values.

C<$var> is replaced by its value,
C<@var> is replaced by "(comma, sparated, list)",
and C<%hash> by "(key => value, ...)" .
Complex expressions with indexing, dereferences, slices
and method calls are also recognized.

Expressions are evaluated in the caller's context using Perl's debugger
hooks, and may refer to almost any lexical or global visible at
the point of call (see "LIMITATIONS").

IMPORTANT: The argument must be single-quoted to prevent Perl
from interpolating it beforehand.

=head2 dvis 'string to be interpolated'

Like C<ivis> with the addition that interpolated items
are prefixed with a "exprtext=" label.

The 'd' in 'dvis' stands for B<d>ebugging messages, a frequent use case where
brevity of typing is more highly prized than beautiful output.

=head2 vis optSCALAREXPR

=head2 avis LIST

=head2 hvis EVENLIST

C<vis> formats a single scalar ($_ if no argument is given)
and returns the resulting string.

C<avis> formats an array (or any list) as comma-separated values in parenthesis.

C<hvis> formats key => value pairs in parenthesis.

=head2 B<< I<Variations> >>

=head3 B<alvis, hlvis>

The "B<l>" variants return a bare list of array or hash members
without the enclosing parenthesis.

=head3 B<ivisq dvisq visq avisq hvisq alvisq hlvisq>

The "B<q>" variants show strings 'single quoted' if possible.

Internally, Data::Dumper is called with C<Useqq(0)>, but depending on
the version of Data::Dumper the result may be "double quoted" anyway
if wide characters are present.

=head3 B<rivis rdvis rvis ravis rhvis rivisq rdvisq rvisq ravisq rhvisq>

The "B<r>" variants show the
I<< type<abbreviated refaddr> >> before refs (see I<addrvis>).  
For example B<rvis([1..3])> returns something like "ARRAYZ<><457:1c9>[1,2,3]".

=head3 B<viso visoq>

The "B<o>" variants show the internals of objects, the same as if
C<$Objects> is set to 0.  By default object internals are never shown,
see I<Objects(BOOL)>.

=head2 addrvis REF

=head2 addrvis NUMBER

These return a string showing the address in both decimal and hexadecimal, 
but abbreviated to only the last few digits.

The number of digits increases over time if necessary to keep new results
unambiguous.

For REFs, the result is like I<< "HASHE<lt>457:1c9E<gt>" >> 
or, for blessed objects, I<< "Package::NameE<lt>457:1c9E<gt>" >>.

If the argument is a plain number, just the abbreviated address
like I<< "E<lt>457:1c9E<gt>" >> is returned.

I<"undef"> is returned if the argument is undefined.

=head1 OBJECT-ORIENTED INTERFACES

=head2 Data::Dumper::Interp->new()

=head2 visnew()

Creates an object initialized from the global configuration
variables listed below
(the function C<visnew> is simply a shorthand wrapper).

No arguments are permitted.

The functions described above may then be called as I<methods>
on the object
(when not called as a method the functions create a new object internally).

For example:

   $msg = visnew->Foldwidth(40)->avis(@ARGV);

returns the same string as

   local $Data::Dumper::Interp::Foldwidth = 40;
   $msg = avis(@ARGV);

=head1 Configuration Variables / Methods

These work the same way as variables/methods in Data::Dumper.

Each config method has a corresponding global variable
in package C<Data::Dumper::Interp> which provides the default.

When a method is called without arguments the current value is returned.

When a method is called with an argument to set a value, the object
is returned so that method calls can be chained.

=head2 MaxStringwidth(INTEGER)

=head2 Truncsuffix("...")

Longer strings are truncated and I<Truncsuffix> appended.
MaxStringwidth=0 (the default) means no limit.

=head2 Foldwidth(INTEGER)

Defaults to the terminal width at the time of first use.

=head2 Objects(BOOL);

=head2 Objects("classname")

=head2 Objects([ list of classnames ])

A I<false> value disables special handling of objects
(that is, blessed things) and internals are shown as with Data::Dumper.

A "1" (the default) enables for all objects,
otherwise only for the specified class name(s) [or derived classes].

When enabled, object internals are never shown.
If the object overloads the stringification ('""') operator,
or array-, hash-, scalar-, or glob- deref operators,
then the first overloaded operator found will be evaluated,
object replaced by the result, and the check repeated; otherwise
only the class and abbreviated address are shown as with C<addrvis>
e.g. "Foo::Bar<392:0f0>".

Beginning with version 5.000 the B<deprecated> C<Overloads> method
is an alias for C<Objects>.

=for Pod::Coverage Overloads btw

=head2 Sortkeys(subref)

The default sorts numeric substrings in keys by numerical
value, e.g. "A.20" sorts before "A.100".  See C<Data::Dumper> documentation.

=head2 Useqq

The default value is "unicode" except for
functions/methods with 'q' in their name, which force C<Useqq(0)>.

0 means generate 'single quoted' strings when possible.

1 means generate "double quoted" strings, as-is from Data::Dumper.
Non-ASCII charcters will be shown as hex escapes.

Otherwise generate "double quoted" strings enhanced according to option
keywords given as a :-separated list, e.g. Useqq("unicode:controlpics").
The avilable options are:

=over 4

=item "unicode"

Printable ("graphic")
characters are shown as themselves rather than hex escapes, and
'\n', '\t', etc. are shown for ASCII control codes.

=item "controlpics"

Show ASCII control characters using single "control picture" characters,
for example '␤' is shown for newline instead of '\n', and
similarly for \0 \a \b \e \f \r and \t.

Every character occupies the same space with a fixed-width font.
However the commonly-used "Last Resort" font for these characters
can be hard to read on modern high-res displays.
Set C<Useqq> to just "unicode" to see traditional \n etc.
backslash escapes while still seeing wide characters as themselves.

=item "spacedots"

Space characters are shown as '·' (Middle Dot).

=item "qq"

=item "qq=XY"

Show using Perl's qq{...} syntax, or qqX...Y if delimiters are specified,
rather than "...".

=back

=head2 Quotekeys

=head2 Maxdepth

=head2 Maxrecurse

=head2 Deparse

See C<Data::Dumper> documentation.

=head1

=head1 UTILITY FUNCTIONS

=head2 u

=head2 u SCALAR

Returns the argument ($_ by default) if it is defined, otherwise
the string "undef".

=head2 quotekey

=head2 quotekey SCALAR

Returns the argument ($_ by default) if it is a valid bareword,
otherwise a "quoted string".

=head2 qsh [$string]

The string ($_ by default) is quoted if necessary for parsing
by the shell (/bin/sh), which has different quoting rules than Perl.
On Win32 quoting is for cmd.com.

If the string contains only "shell-safe" ASCII characters
it is returned as-is, without quotes.

If the argument is a ref but is not an object which stringifies,
then vis() is called and the resulting string quoted.
An undefined value is shown as C<undef> without quotes;
as a special case to avoid ambiguity the string 'undef' is always "quoted".

=head2 qshpath [$might_have_tilde_prefix]

Similar to C<qsh> except that an initial ~ or ~username is left
unquoted.  Useful for paths given to bash or csh.

=head2 qshlist @items

Format e.g. a shell command and arguments, quoting when necessary.

Returns a string with the items separated by spaces.

=head1 LIMITATIONS

=over 2

=item Interpolated Strings

C<ivis> and C<dvis> evaluate expressions in the user's context
using Perl's debugger support ('eval' in package DB -- see I<perlfunc>).
This mechanism has some limitations:

@_ will appear to have the original arguments to a sub even if "shift"
has been executed.  However if @_ is entirely replaced, the correct values
will be displayed.

A lexical ("my") sub creates a closure, and variables in visible scopes
which are not actually referenced by your code may not exist in the closure;
an attempt to display them with C<ivis> will fail.  For example:

    our $global;
    sub outerfunc {
      my sub inner {
        say dvis '$global'; # croaks with "Error interpolating '$global'"
        # my $x = $global;  # ... unless this is un-commented
      }
      &inner();
    }
    &outerfunc;


=item Multiply-referenced items

If a structure contains several refs to the same item,
the first ref will be visualized by showing the referenced item
as you might expect.

However subsequent refs will look like C<< $VAR1->place >>
where C<place> is the location of the first ref in the overall structure.
This is how Data::Dumper indicates that the ref is a copy of the first
ref and thus points to the same datum.
"$VAR1" is an artifact of how Data::Dumper would generate code
using its "Purity" feature.  Data::Dumper::Interp does nothing
special and simply passes through these annotations.

=item The special "_" stat filehandle may not be preserved

Data::Dumper::Interp queries the operating
system to obtain the window size to initialize C<$Foldwidth>, if it
is not already defined; this may change the "_" filehandle.
After the first call (or if you pre-set C<$Foldwidth>),
the "_" filehandle will not change across calls.

=back

=head1 DIFFERENCES FROM Data::Dumper

Results differ from plain C<Data::Dumper> output in the following ways
(most substitutions can be disabled via Config options):

=over 2

=item *

A final newline is I<never> included.

Everything is shown on a single line if possible, otherwise wrapped to
your terminal width (or C<$Foldwidth>) with indentation
appropriate to structure levels.

=item *

Printable Unicode characters appear as themselves instead of \x{ABCD}.

Note: If your data contains 'wide characters', you should
C<< use open IO => ':locale'; >> or otherwise arrange to
encode the output for your terminal.
You'll also want C<< use utf8; >> if your Perl source
contains characters outside the ASCII range.

Undecoded binary octets (e.g. data read from a 'binmode' file)
will still be escaped as individual bytes when necessary.

=item *

Spaces·may·be·shown·visibly.

=item *

'␤' may be shown for newline, and similarly for other ASCII control characters.

=item *

The internals of objects are not shown by default.

If stringifcation is overloaded it is used to obtain the object's
representation.  For example, C<bignum> and C<bigrat> numbers are shown as easily
readable values rather than S<"bless( {...}, 'Math::...')">.

Stingified objects are prefixed with "(classname)" to make clear what
happened.

The "virtual" value of objects which overload a dereference operator
(C<@{}> or C<%{}>) is displayed instead of the object's internals.

=item *

Hash keys are sorted treating numeric "components" numerically.
For example "A.20" sorts before "A.100".

=item *

Punctuation variables such as $@, $!, and $?, are preserved over calls.

=item *

Numbers and strings which look like numbers are kept distinct when displayed,
i.e. "0" does not become 0 or vice-versa. Floating-point values are shown
as numbers not 'quoted strings' and similarly for stringified objects.

Although such differences might be immaterial to Perl during execution,
they may be important when communicating to a human.

=back

=head1 SEE ALSO

Data::Dumper

Jim Avera  (jim.avera AT gmail)

=for nobody Foldwidth1 is currently an undocumented experimental method
=for nobody which sets a different fold width for the first line only.
=for nobody
=for nobody viso & visoq are also undocumented experimental
=for nobody
=for nobody oops is an internal function (called to die if bug detected).
=for nobody
=for nobody The Debug method is for author's debugging, and not documented.

=for Pod::Coverage viso visoq Foldwidth1 oops Debug

=cut
