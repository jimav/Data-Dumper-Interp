#!/usr/bin/perl
use strict; use warnings  FATAL => 'all'; use feature qw(state say); 
srand(42);  # so reproducible
use feature 'lexical_subs'; no warnings "experimental::lexical_subs";
use version 0.77;
#use open IO => ':locale';
use open ':std', ':encoding(UTF-8)';
use utf8;
select STDERR; $|=1; select STDOUT; $|=1;
use Scalar::Util qw(blessed reftype looks_like_number);
use Carp;
$SIG{__WARN__} = sub { confess "warning trapped; @_" };
use English qw( -no_match_vars );;
use Data::Compare qw(Compare);

confess "Non-zero CHILD_ERROR ($?)" if $? != 0;

# This script was written before the author knew anything about standard
# Perl test-harness tools.  Perhaps someday it will be wholely rewritten.
# Meanwhile, some baby steps...
use Test::More;

use Data::Dumper::Interp;
diag "Loaded ", $INC{"Data::Dumper::Interp.pm" =~ s/::/\//gr}, 
     " VERSION=", ($Data::Dumper::Interp::VERSION // "undef"),"\n"; 

confess "Non-zero CHILD_ERROR ($?)" if $? != 0;

# Format a Unicode string in «french quotes» and also with hex escapes
# (so we can still see something useful on non-Unicode platforms).
sub displaystr($) {
  my ($input) = @_;
  return "undef" if ! defined($input);
  chomp( my $s = Data::Dumper->new([$input])->Useqq(1)->Terse(1)->Indent(0)->Dump );
  "«${input}»($s)"
}

# Do an initial read of $[ so arybase will be autoloaded
# (prevents corrupting $!/ERRNO in subsequent tests)
eval '$[' // die;

#$Data::Dumper::Interp::Debug = 1;

#sub _dbvis(_) { goto &Data::Dumper::Interp::_dbvis }
#sub _dbvisq(_) { goto &Data::Dumper::Interp::_dbvisq }
#sub _dbavis(_) { goto &Data::Dumper::Interp::_dbavis }

sub fmt_codestring($;$) { # returns list of lines
  my ($str, $prefix) = @_;
  $prefix //= "line ";
  my $i=1; map{ sprintf "%s%2d: %s\n", $prefix,$i++,$_ } (split /\n/,$_[0]);
}

sub timed_run(&$@) {
  my ($code, $maxcpusecs, @codeargs) = @_;

  eval { require Time::HiRes };
  my $getcpu = defined(eval{ &Time::HiRes::clock() }) 
    ? \&Time::HiRes::clock : sub{ my @t = times; $t[0]+$t[1] };
  
  my $startclock = &$getcpu();
  my (@result, $result);
  if (wantarray) {@result = &$code(@codeargs)} else {$result = &$code(@codeargs)};
  my $cpusecs = &$getcpu() - $startclock;
  confess "TOOK TOO LONG ($cpusecs CPU seconds vs. limit of $maxcpusecs)\n"
    if $cpusecs > $maxcpusecs;
  if (wantarray) {return @result} else {return $result};
}

sub visFoldwidth() {
  "Data::Dumper::Interp::Foldwidth=".u($Data::Dumper::Interp::Foldwidth)
 ." Foldwidth1=".u($Data::Dumper::Interp::Foldwidth1)
 .($Data::Dumper::Interp::Foldwidth ? ("\n".("." x $Data::Dumper::Interp::Foldwidth)) : "")
}
sub checkeq_literal($$$) {
  my ($testdesc, $exp, $act) = @_;
  $exp = show_white($exp); # stringifies undef
  $act = show_white($act);
  return unless $exp ne $act;
  my $posn = 0;
  for (0..length($exp)) {
    my $c = substr($exp,$_,1);
    last if $c ne substr($act,$_,1);
    $posn = $c eq "\n" ? 0 : ($posn + 1);
  }
  @_ = ( "\n**************************************\n"
        ."${testdesc}\n"
        ."Expected:\n".displaystr($exp)."\n"
        ."Actual  :\n".displaystr($act)."\n"
        .(" " x ($posn+1))."^\n" # +1 for the opening « in the displayed str
        .visFoldwidth()."\n" ) ;
  goto &Carp::confess;
}

# USAGE: check $code_display, qr/$exp/, $doeval->($code, $item) ;
# { my $code="Data::Dumper::Interp->new->hvis(k=>'v');"; check $code, '(k => "v")',eval $code }
sub check($$@) {
  my ($code, $expected_arg, @actual) = @_;
  local $_;  # preserve $1 etc. for caller
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
             ."Got:\n".displaystr($actual)."\n"
             .visFoldwidth()
        unless $actual =~ ($expected // "Never Matched");
    } else {
      checkeq_literal "TESTc FAILED: $code", $expected, $actual;
    }
  }
}

# Run a variety of tests on an item which is a string or strigified object
# which is not presented as a bare number (i.e. it is shown in quotes).
# The caller provides a sub which does the eval in the desired context,
# for example with "use bignum".
# The expected_re matches the item without surrounding quotes.
# **CURRENTLY NO LONGER USED** (3/12/2022)
#sub checkstringy(&$$) {
#  my ($doeval, $item, $expected_re) = @_;
#  my $expqq_re = "\"${expected_re}\"";
#  my $expq_re  = "'${expected_re}'";
#  foreach (
#    [ 'Data::Dumper::Interp->new()->vis($_[1])',  '_Q_' ],
#    [ 'vis($_[1])',              '_Q_' ],
#    [ 'visq($_[1])',             '_q_' ],
#    [ 'avis($_[1])',             '(_Q_)' ],
#    [ 'avisq($_[1])',            '(_q_)' ],
#    #currently broken due to $VAR problem: [ 'avisq($_[1], $_[1])',     '(_q_, _q_)' ],
#    [ 'alvis($_[1])',             '_Q_' ],
#    [ 'alvisq($_[1])',            '_q_' ],
#    [ 'ivis(\'$_[1]\')',         '_Q_' ],
#    [ 'ivis(\'foo$_[1]\')',      'foo_Q_' ],
#    [ 'ivis(\'foo$\'."_[1]")',   'foo_Q_' ],
#    [ 'dvis(\'$_[1]\')',         '$_[1]=_Q_' ],
#    [ 'dvis(\'foo$_[1]bar\')',   'foo$_[1]=_Q_bar' ],
#    [ 'dvisq(\'foo$_[1]\')',     'foo$_[1]=_q_' ],
#    [ 'dvisq(\'foo$_[1]bar\')',  'foo$_[1]=_q_bar' ],
#    [ 'vis({ aaa => $_[1], bbb => "abc" })', '{aaa => _Q_,bbb => "abc"}' ],
#  ) {
#    my ($code, $exp) = @$_;
#    $exp = quotemeta $exp;
#    $exp =~ s/_Q_/$expqq_re/g;
#    $exp =~ s/_q_/$expq_re/g;
#    my $code_display = $code . " with \$_[1]=«$item»";
#    local $Data::Dumper::Interp::Foldwidth = 0;  # disable wrapping
#    check $code_display, qr/$exp/, $doeval->($code, $item) ;
#  }
#}#checkstringy()

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
  foreach (
    [ "Data::Dumper::Interp->new()->vis(\$_[1])",  '_Q_' ],
    [ 'vis($_[1])',              '_Q_' ],
    [ 'visq($_[1])',             '_q_' ],
    [ 'avis($_[1])',             '(_Q_)' ],
    [ 'avisq($_[1])',            '(_q_)' ],
    #currently broken due to $VAR problem: [ 'avisq($_[1], $_[1])',     '(_q_, _q_)' ],
    [ 'alvis($_[1])',             '_Q_' ],
    [ 'alvisq($_[1])',            '_q_' ],
    [ 'ivis(\'$_[1]\')',         '_Q_' ],
    [ 'ivis(\'foo$_[1]\')',      'foo_Q_' ],
    [ 'ivis(\'foo$\'."_[1]")',   'foo_Q_' ],
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
    local $Data::Dumper::Interp::Foldwidth = 0;  # disable wrapping
    check $code_display, qr/$exp/, $doeval->($code, $item) ;
  }
}#checklit()

# Basic test of OO interfaces
{ my $code="Data::Dumper::Interp->new->vis('foo')  ;"; check $code, '"foo"',     eval $code }
{ my $code="Data::Dumper::Interp->new->avis('foo') ;"; check $code, '("foo")',   eval $code }
{ my $code="Data::Dumper::Interp->new->hvis(k=>'v');"; check $code, '(k => "v")',eval $code }
{ my $code="Data::Dumper::Interp->new->dvis('foo') ;"; check $code, 'foo',       eval $code }
{ my $code="Data::Dumper::Interp->new->ivis('foo') ;"; check $code, 'foo',       eval $code }

foreach (
          ['Foldwidth',0,1,80,9999],
          ['MaxStringwidth',undef,0,1,80,9999],
          ['Truncsuffix',"","...","(trunc)"],
          ## FIXME: This will spew debug messages.  Trap them somehow??
          #['Debug',undef,0,1],
          # Now the 'q' interfaces force Useqq(0) internally
          # ['Useqq',0,1,'utf8'],
          ['Quotekeys',0,1],
          ['Sortkeys',0,1,sub{ [ sort keys %{shift @_} ] } ],
          # Changing Indent and Terse are no longer allowed.
          # ['Terse',0,1],
          # ['Indent',0,1,2,3],
          ['Sparseseen',0,1,2,3],
        )
{
  my ($confname, @values) = @$_;
  foreach my $value (@values) {
    foreach my $base (qw(vis avis hvis alvis hlvis dvis ivis)) {
      foreach my $q ("", "q") {
        my $dumper = $base . $q . "(42";
         $dumper .= ", 43" if $base =~ /^[ahl]/;
         $dumper .= ")";
        {
          my $v = eval "{ local \$Data::Dumper::Interp::$confname = \$value;
                          my \$obj = Data::Dumper::Interp->new();
                          \$obj->$dumper ;   # discard dump result
                          \$obj->$confname() # fetch effective setting
                        }";
        confess "bug:$@ " if $@;
        confess "\$Data::Dumper::Interp::$confname value is not preserved by $dumper\n",
            "(Set \$Data::Dumper::Interp::$confname=",u($value)," but new()...->$confname() returned ",u($v),")\n"
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
$Data::Dumper::Interp::Foldwidth = 72;

@ARGV = ('fake','argv');
$. = 1234;
$ENV{EnvVar} = "Test EnvVar Value";


my %toplex_h = ("" => "Emp", A=>111,"B B"=>222,C=>{d=>888,e=>999},D=>{},EEEEEEEEEEEEEEEEEEEEEEEEEE=>\42,F=>\\\43, G=>qr/foo.*bar/xsi);
   # EEE... identifer is long to force linewrap
my @toplex_a = (0,1,"C",\%toplex_h,[],[0..9]);
my $toplex_ar = \@toplex_a;
my $toplex_hr = \%toplex_h;
my $toplex_obj = bless {}, 'MyClass';
my $toplex_regexp= qr/my.*regexp/;

our %global_h = %toplex_h;
our @global_a = @toplex_a;
our $global_ar = \@global_a;
our $global_hr = \%global_h;
our $global_obj = bless {}, 'MyClass';
our $global_regexp = $toplex_regexp;

our %maskedglobal_h = (key => "should never be seen");
our @maskedglobal_a = ("should never be seen");
our $maskedglobal_ar = \@maskedglobal_a;
our $maskedglobal_hr = \%maskedglobal_h;
our $maskedglobal_obj = bless {}, 'ShouldNeverBeUsedClass';
our $maskedglobal_regexp = qr/should.*never.*be_seen/;

our %local_h = (key => "should never be seen");
our @local_a = ("should never be seen");
our $local_ar = \@local_a;
our $local_hr = \%local_h;
our $local_obj = \%local_h;
our $local_regexp = qr/should.*never.*be_seen/;

our $a = "global-a";  # used specially used by sort()
our $b = "global-b";

package A::B::C;
our %ABC_h = %main::global_h;
our @ABC_a = @main::global_a;
our $ABC_ar = \@ABC_a;
our $ABC_hr = \%ABC_h;
our $ABC_obj = $main::global_obj;
our $ABC_regexp = $main::global_regexp;

package main;

$_ = "GroupA.GroupB";
/(.*)\W(.*)/sp or die "nomatch"; # set $1 and $2

{ my $code = 'qsh("a b")';           check $code, '"a b"',  eval $code; }
{ my $code = 'qsh(undef)';           check $code, "undef",  eval $code; }
{ my $code = 'qsh("undef")';         check $code, "\"undef\"",  eval $code; }
{ my $code = 'qshpath("a b")';       check $code, '"a b"',  eval $code; }
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
{ my $code = 'ivis(undef)'; check $code, "<undef arg>", eval $code; }
{ my $code = 'dvis(undef)'; check $code, "<undef arg>", eval $code; }
{ my $code = 'dvisq(undef)'; check $code, "<undef arg>", eval $code; }
{ my $code = 'vis(\undef)'; check $code, "\\undef", eval $code; }
{ my $code = 'vis(\123)'; check $code, "\\123", eval $code; }
{ my $code = 'vis(\"xy")'; check $code, "\\\"xy\"", eval $code; }

{ my $code = q/my $s; my @a=sort{ $s=dvis('$a $b'); $a<=>$b }(3,2); "@a $s"/ ;
  check $code, '2 3 a=3 b=2', eval $code;
}

# Vis v1.147ish+ : Check corner cases of re-parsing code 
{ my $code = q(my $v = undef; dvis('$v')); check $code, "v=undef", eval $code; }
{ my $code = q(my $v = \undef; dvis('$v')); check $code, "v=\\undef", eval $code; }
{ my $code = q(my $v = \"abc"; dvis('$v')); check $code, 'v=\\"abc"', eval $code; }
{ my $code = q(my $v = \"abc"; dvisq('$v')); check $code, "v=\\'abc'", eval $code; }
{ my $code = q(my $v = \*STDOUT; dvisq('$v')); check $code, "v=\\*::STDOUT", eval $code; }
SKIP: {
  skip "because Data::Dumper too old", 1 
    if version->parse($Data::Dumper::VERSION) <= version->parse(2.179);
  { my $code = q(open my $fh, "</dev/null" or die; dvis('$fh')); 
    check $code, "fh=\\*{\"::\\\$fh\"}", eval $code; }
}
{ my $code = q(open my $fh, "</dev/null" or die; dvisq('$fh')); 
  check $code, "fh=\\*{'::\$fh'}", eval $code; }

# Data::Dumper::Interp 2.12 : hex escapes including illegal code points:
#   10FFFF is the highest legal Unicode code point which will ever be assigned.
# Perl (v5.34 at least) mandates code points be <= max signed integer,
# which on 32 bit systems is 7FFFFFFF.
{ my $code = q(my $v = "beyondmax:\x{110000}\x{FFFFFF}\x{7FFFFFFF}"; dvis('$v')); 
  check $code, 'v="beyondmax:\x{110000}\x{ffffff}\x{7fffffff}"', eval $code; }

# Check that $1 etc. can be passed (this was once a bug...)
# The duplicated calls are to check that $1 is preserved
{ my $code = '" a~b" =~ / (.*)()/ && qsh($1); die unless $1 eq "a~b";qsh($1)'; 
  check $code, '"a~b"', eval $code; }
{ my $code = '" a~b" =~ / (.*)()/ && qshpath($1); die unless $1 eq "a~b";qshpath($1)'; 
  check $code, '"a~b"', eval $code; }
{ my $code = '" a~b" =~ / (.*)()/ && vis($1); die unless $1 eq "a~b";vis($1)'; 
  check $code, '"a~b"', eval $code; }
{ my $code = 'my $vv=123; \' a $vv b\' =~ / (.*)/ && dvis($1); die unless $1 eq "a \$vv b"; dvis($1)'; 
  check $code, 'a vv=123 b', eval $code; }

# Check Deparse support
{ my $data = eval 'BEGIN{ ${^WARNING_BITS} = 0 } no strict; no feature;
                   sub{ my $x = 42; };';
  { my $code = 'vis($data)'; check $code, 'sub { "DUMMY" }', eval $code; }
  local $Data::Dumper::Interp::Deparse = 1;
  { my $code = 'vis($data)'; check $code, qr/sub \{\s*my \$x = 42;\s*\}/, eval $code; }
}

# Floating point values (single values special-cased to show not as 'string')
{ my $code = 'vis(3.14)'; check $code, '3.14', eval $code; }
# But multiple values are sent through Data::Dumper, so...
{ my $code = 'vis([3.14])'; check $code, '[3.14]', eval $code; }

# bigint, bignum, bigrat support
#
# Recently Data::Dumper::Interp was changed to prepend (objtype) to stringified values,
# e.g. "(Math::BigFloat)3.14159265358979323846264338327950288419"
# but we might later change this back, or make the prefix optional;
# therefore we accept the result with or without with (type) prefix.

my $bigfstr = '9988776655443322112233445566778899.8877';
my $bigistr = '9988776655443322112233445566778899887766';
my $ratstr  = '1/9';

{
  use bignum;  # BigInt and BigFloat together

  # stringify everything possible
  local $Data::Dumper::Interp::Overloads = 1;  # NOTE: the '1' will be a BigInt !

  my $bigf = eval $bigfstr // die;
  die unless blessed($bigf) =~ /^Math::BigFloat/;
  checklit(sub{eval $_[0]}, $bigf, qr/(?:\(Math::BigFloat[^\)]*\))?${bigfstr}/);

  my $bigi = eval $bigistr // die;
  die unless blessed($bigi) =~ /^Math::BigInt/;
  checklit(sub{eval $_[0]}, $bigi, qr/(?:\(Math::BigInt[^\)]*\))?${bigistr}/);

  # Confirm that various Overloads values disable
  foreach my $Sval (0, undef, "", [], [0], [""]) {
    local $Data::Dumper::Interp::Overloads = $Sval;
    my $s = vis($bigf);
    die "bug(",u($Sval),")($s)" unless $s =~ /^\(?bless.*BigFloat/s;
  }
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
  { local $Data::Dumper::Interp::Overloads = 0;
    my $s = vis($bigf); die "bug($s)" unless $s =~ /^bless.*BigFloat/s;
  }
  # With explicit stringification of BigFloat only
  { local $Data::Dumper::Interp::Overloads = [qr/^Math::BigFloat/];
    checklit(sub{eval $_[0]}, $bigf, qr/(?:\(Math::BigFloat[^\)]*\))?${bigfstr}/);
    # But not other classes
    my $s = vis($rat); die "bug($s)" unless $s =~ /^bless.*BigRat/s;
  }
}

{
  # There is a new (with bigrat 0.51) bug where "use bigrat" immediately and
  # permanently causes math operations on Math::BitFloat to produce BigRats in all 
  # scopes, not just in the scope of the 'use bigrat'.   This breaks Math::BigFloat
  # tests which execute after the bigrat package is loaded.
  #
  # So we have to do the bigrat test in an eval to defer loading it until after
  # all other bignum tests have run.
  # Arrgh!
  eval <<'EOF';
    use bigrat;
    my $rat = eval $ratstr // die;
    die unless blessed($rat) =~ /^Math::BigRat/;
    checklit(sub{eval $_[0]}, $rat, qr/(?:\(Math::BigRat[^\)]*\))?${ratstr}/);
EOF
  die "urp\n$@" if $@
}

# Check string truncation, and that the original data is not modified in-place
{ my $orig_str  = '["abcDEFG",["xyzABCD",{bareword => "fghIJKL"}]]';
  my $check_data = eval $orig_str; die "bug" if $@;
  my $orig_data  = eval $orig_str; die "bug" if $@;
  foreach my $MSw (1..9) {
    # hand-truncate to create "expected result" data
    (my $exp_str = $orig_str) =~ s{("?)([a-zA-Z]{$MSw})([a-zA-Z]*+)(\1)}{
                                    local $_ = $1
                                             . $2 
                                             . (length($3) > 3 ? "..." : $3)
                                             . $4 ;
                                    $_ = "\"$_\"" if m{^\w.*\.\.\.$}; #bareword
                                    $_
                                  }segx;
    local $Data::Dumper::Interp::MaxStringwidth = $MSw;
    check "with MaxStringwidth=$MSw", $exp_str, eval 'vis($orig_data)';
    die "MaxStringwidth=$MSw : Original data corrupted"
      unless Compare($orig_data, $check_data);
  }
}

# There was a bug for s/dvis called direct from outer scope, so don't use eval:
check 
  'global divs %toplex_h',
q(%toplex_h=( "" => "Emp",A => 111,"B B" => 222,C => {d => 888,e => 999},
  D => {},EEEEEEEEEEEEEEEEEEEEEEEEEE => \\42,F => \\\\\\43,
  G => qr/foo.*bar/six
)),
  dvis('%toplex_h');
check 'global divs @ARGV', q(@ARGV=("fake","argv")), dvis('@ARGV');
check 'global divs $.', q($.=1234), dvis('$.');
check 'global divs $ENV{EnvVar}', q("Test EnvVar Value"), ivis('$ENV{EnvVar}');
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
        '@backtrack_bugtest_data=(42,{A => 0,BBBBBBBBBBBBB => "foo"})',
        dvis('@backtrack_bugtest_data');
} 0.05; # was 0.01 but that failed on slow arm machines

sub doquoting($$) {
  my ($input, $useqq) = @_;
  my $quoted = $input;
  if ($useqq) {
    my %subopts;
    if ($useqq ne "1") {
      foreach my $item (split /:/, $useqq) {
        if ($item =~ /^([^=]+)=(.*)/) {
          $subopts{$1} = $2;
        } else {
          $subopts{$item} = 1;
        }
      }
    }
    $quoted =~ s/([\$\@\\])/\\$1/gs;
    if (delete $subopts{controlpic}) {
      $quoted =~ s/\n/\N{SYMBOL FOR NEWLINE}/gs;
      $quoted =~ s/\t/\N{SYMBOL FOR HORIZONTAL TABULATION}/gs;
    } else {
      $quoted =~ s/\n/\\n/gs;
      $quoted =~ s/\t/\\t/gs;
    }
    my $unicode = delete $subopts{unicode} || delete $subopts{utf8};
    if (!$unicode) {
      $quoted = join("", map{ ord($_) > 127 ? sprintf("\\x{%x}", ord($_)) : $_ } 
                           split //,$quoted);
    }
    if (my $arg = delete $subopts{qq}) {
      my ($left, $right) = split //, ($arg eq 1 ? "{}" : $arg);
      $quoted =~ s/([\Q${left}${right}\E])/\\$1/g;
      $quoted = "qq" . $left . $quoted . $right;
    } else {
      $quoted =~ s/"/\\"/g;
      $quoted = '"' . $quoted . '"';
    }
    confess "testbug: Useqq subopt: '",keys(%subopts),"'\n" if %subopts;
  } else {
    $quoted =~ s/([\\'])/\\$1/gs;
    $quoted = "'${quoted}'";
  }
  return $quoted;
}

sub show_white($) {
  local $_ = shift;
  return "(Is undef)" unless defined;
  s/\t/<tab>/sg;
  s/( +)$/"<space>" x length($1)/seg; # only trailing spaces
  s/\n/<newline>\n/sg;
  $_
}

my $unicode_str = join "", map { chr($_) } (0x263A .. 0x2650);
my $byte_str = join "",map { chr $_ } 10..30;

sub get_closure(;$) {
 my ($clobber) = @_;
 confess "Non-zero CHILD_ERROR ($?)" if $? != 0;

 my %closure_h = (%toplex_h);
 my @closure_a = (@toplex_a);
 my $closure_ar = \@closure_a;
 my $closure_hr = \%closure_h;
 my $closure_obj = $toplex_obj;
 if ($clobber) { # try to over-write deleted objects
   @closure_a = ("bogusa".."bogusz");
 }

 return sub {

  confess "Non-zero CHILD_ERROR ($?)" if $? != 0;

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
  my %sublexx_h = %toplex_h;
  my @sublexx_a = @toplex_a;
  my $sublexx_ar = \@sublexx_a;
  my $sublexx_hr = \%sublexx_h;
  my $sublexx_obj = $toplex_obj;
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
  our $maskedglobal_regexp = $toplex_regexp;
  local %local_h = %toplex_h;
  local @local_a = @toplex_a;
  local $local_ar = \@toplex_a;
  local $local_hr = \%local_h;
  local $local_obj = $toplex_obj;
  local $local_regexp = $toplex_regexp;

  my @dvis_tests = (
    [ __LINE__, q(hexesc:\x{263a}), qq(hexesc:\N{U+263A}) ],   # \x{...} in dvis input
    [ __LINE__, q(NUesc:\N{U+263a}), qq(NUesc:\N{U+263A}) ], # \N{U+...} in dvis input
    [ __LINE__, q(aaa\\\\bbb), q(aaa\bbb) ],
    [ __LINE__, q(re is $toplex_regexp), q(re is toplex_regexp=qr/my.*regexp/) ],

    #[ q($unicode_str\n), qq(unicode_str=\" \\x{263a} \\x{263b} \\x{263c} \\x{263d} \\x{263e} \\x{263f} \\x{2640} \\x{2641} \\x{2642} \\x{2643} \\x{2644} \\x{2645} \\x{2646} \\x{2647} \\x{2648} \\x{2649} \\x{264a} \\x{264b} \\x{264c} \\x{264d} \\x{264e} \\x{264f} \\x{2650}\"\n) ],
    [__LINE__, q($unicode_str\n), qq(unicode_str="${unicode_str}"\n) ],

    [__LINE__, q(unicodehex_str=\"\\x{263a}\\x{263b}\\x{263c}\\x{263d}\\x{263e}\\x{263f}\\x{2640}\\x{2641}\\x{2642}\\x{2643}\\x{2644}\\x{2645}\\x{2646}\\x{2647}\\x{2648}\\x{2649}\\x{264a}\\x{264b}\\x{264c}\\x{264d}\\x{264e}\\x{264f}\\x{2650}\"\n), qq(unicodehex_str="${unicode_str}"\n) ],

    [__LINE__, q($byte_str\n), qq(byte_str=\"\N{SYMBOL FOR NEWLINE}\\13\N{SYMBOL FOR FORM FEED}\N{SYMBOL FOR CARRIAGE RETURN}\\16\\17\\20\\21\\22\\23\\24\\25\\26\\27\\30\\31\\32\N{SYMBOL FOR ESCAPE}\\34\\35\\36\"\n) ],
    #[__LINE__, q($byte_str\n), qq(byte_str=\"\\n\\13\\f\\r\\16\\17\\20\\21\\22\\23\\24\\25\\26\\27\\30\\31\\32\\e\\34\\35\\36\"\n) ],
    #[__LINE__, q($byte_str\n), qq(byte_str=\"\\n\\x{B}\\f\\r\\x{E}\\x{F}\\x{10}\\x{11}\\x{12}\\x{13}\\x{14}\\x{15}\\x{16}\\x{17}\\x{18}\\x{19}\\x{1A}\\e\\x{1C}\\x{1D}\\x{1E}\"\n) ],

    [__LINE__, q($flex\n), qq(flex=\"Lexical in sub f\"\n) ],
    [__LINE__, q($$flex_ref\n), qq(\$\$flex_ref=\"Lexical in sub f\"\n) ],

    [__LINE__, q($_ $ARG\n), qq(\$_=\"GroupA.GroupB\" ARG=\"GroupA.GroupB\"\n) ],
    [__LINE__, q($a\n), qq(a=\"global-a\"\n) ],
    [__LINE__, q($b\n), qq(b=\"global-b\"\n) ],
    [__LINE__, q($1\n), qq(\$1=\"GroupA\"\n) ],
    [__LINE__, q($2\n), qq(\$2=\"GroupB\"\n) ],
    [__LINE__, q($3\n), qq(\$3=undef\n) ],
    [__LINE__, q($&\n), qq(\$&=\"GroupA.GroupB\"\n) ],
    [__LINE__, q(${^MATCH}\n), qq(\${^MATCH}=\"GroupA.GroupB\"\n) ],
    [__LINE__, q($.\n), qq(\$.=1234\n) ],
    [__LINE__, q($NR\n), qq(NR=1234\n) ],
    [__LINE__, q($/\n), qq(\$/=\"\N{SYMBOL FOR NEWLINE}\"\n) ],
    #[__LINE__, q($/\n), qq(\$/=\"\\n\"\n) ],
    [__LINE__, q($\\\n), qq(\$\\=undef\n) ],
    [__LINE__, q($"\n), qq(\$\"=\" \"\n) ],
    [__LINE__, q($~\n), qq(\$~=\"STDOUT\"\n) ],
    #20 :
    [__LINE__, q($^\n), qq(\$^=\"STDOUT_TOP\"\n) ],
    [__LINE__, q($:\n), qq(\$:=\" \N{SYMBOL FOR NEWLINE}-\"\n) ],
    #[__LINE__, q($:\n), qq(\$:=\" \\n-\"\n) ],
    [__LINE__, q($^L\n), qq(\$^L=\"\N{SYMBOL FOR FORM FEED}\"\n) ],
    [__LINE__, q($?\n), qq(\$?=0\n) ],
    [__LINE__, q($[\n), qq(\$[=0\n) ],
    [__LINE__, q($$\n), qq(\$\$=$$\n) ],
    [__LINE__, q($^N\n), qq(\$^N=\"GroupB\"\n) ],
    [__LINE__, q($+\n), qq(\$+=\"GroupB\"\n) ],
    [__LINE__, q(@+ $#+\n), qq(\@+=(13,6,13) \$#+=2\n) ],
    [__LINE__, q(@- $#-\n), qq(\@-=(0,0,7) \$#-=2\n) ],
    #30 :
    [__LINE__, q($;\n), qq(\$;=\"\\34\"\n) ],
    #[__LINE__, q($;\n), qq(\$;=\"\\x{1C}\"\n) ],
    [__LINE__, q(@ARGV\n), qq(\@ARGV=(\"fake\",\"argv\")\n) ],
    [__LINE__, q($ENV{EnvVar}\n), qq(\$ENV{EnvVar}=\"Test EnvVar Value\"\n) ],
    [__LINE__, q($ENV{$EnvVarName}\n), qq(\$ENV{\$EnvVarName}=\"Test EnvVar Value\"\n) ],
    [__LINE__, q(@_\n), <<'EOF' ],  # N.B. Foldwidth was set to 72
@_=( 42,
  [ 0,1,"C",
    { "" => "Emp",A => 111,"B B" => 222,C => {d => 888,e => 999},
      D => {},EEEEEEEEEEEEEEEEEEEEEEEEEE => \42,F => \\\43,
      G => qr/foo.*bar/six
    },[],[0,1,2,3,4,5,6,7,8,9]
  ]
)
EOF
    [__LINE__, q($#_\n), qq(\$#_=1\n) ],
    [__LINE__, q($@\n), qq(\$\@=\"FAKE DEATH\N{SYMBOL FOR NEWLINE}\"\n) ],
    #37 :
    map({
      my ($LQ,$RQ) = (/^(.)(.)$/) or die "bug";
      map({
        my $name = $_;
        map({
          my ($dollar, $r) = @$_;
          my $dolname_scalar = $dollar ? "\$$name" : $name;
          # Make total prefix length constant to avoid wrap variations
          my $maxnamelen = 12;
          my $spfx = "x" x (
            (1+1+$maxnamelen+1)  # {dollar}$name{r}
            - (length($dollar)+length($dolname_scalar)+length($r)) );
          my $pfx = substr($spfx,0,length($spfx)-1);
          #state $depth=0;
          #say "##($depth) spfx=<$spfx> pfx=<$pfx> dollar=<$dollar> r=<$r> dns=<$dolname_scalar> n=<$name>"; $depth++;
          
          #my $p = " " x length("?${dollar}${name}_?${r}");
          my $p = "";

          [__LINE__, qq(${pfx}%${dollar}${name}_h${r}\n), <<EOF ],
${pfx}\%${dollar}${name}_h${r}=( "" => "Emp",A => 111,"B B" => 222,
${p}  C => {d => 888,e => 999},D => {},EEEEEEEEEEEEEEEEEEEEEEEEEE => \\42,
${p}  F => \\\\\\43,G => qr/foo.*bar/six
${p})
EOF

          [__LINE__, qq(${pfx}\@${dollar}${name}_a${r}\n), <<EOF ],
${pfx}\@${dollar}${name}_a${r}=( 0,1,"C",
${p}  { "" => "Emp",A => 111,"B B" => 222,C => {d => 888,e => 999},D => {},
${p}    EEEEEEEEEEEEEEEEEEEEEEEEEE => \\42,F => \\\\\\43,G => qr/foo.*bar/six
${p}  },[],[0,1,2,3,4,5,6,7,8,9]
${p})
EOF

          [__LINE__, qq(${pfx}\$#${dollar}${name}_a${r}),    
            qq(${pfx}\$#${dollar}${name}_a${r}=5)   
          ],
          [__LINE__, qq(${pfx}\$#${dollar}${name}_a${r}\n), 
            qq(${pfx}\$#${dollar}${name}_a${r}=5\n) 
          ],

          [__LINE__, qq(${spfx}\$${dollar}${name}_a${r}[3]{C}{e}\n),
            qq(${spfx}\$${dolname_scalar}_a${r}[3]{C}{e}=999\n)
          ],

          [__LINE__, qq(${spfx}\$${dollar}${name}_a${r}[3]->{A}\n),
            qq(${spfx}\$${dolname_scalar}_a${r}[3]->{A}=111\n)
          ],
          [__LINE__, qq(${spfx}\$${dollar}${name}_a${r}[3]->{$LQ$RQ}\n),
            qq(${spfx}\$${dolname_scalar}_a${r}[3]->{$LQ$RQ}="Emp"\n)
          ],
          [__LINE__, qq(${spfx}\$${dollar}${name}_a${r}[3]{C}->{e}\n),
            qq(${spfx}\$${dolname_scalar}_a${r}[3]{C}->{e}=999\n)
          ],
          [__LINE__, qq(${spfx}\$${dollar}${name}_a${r}[3]->{C}->{e}\n),
            qq(${spfx}\$${dolname_scalar}_a${r}[3]->{C}->{e}=999\n)
          ],
          [__LINE__, qq(${spfx}\@${dollar}${name}_a${r}[\$zero,\$one]\\n),
            qq(${spfx}\@${dollar}${name}_a${r}[\$zero,\$one]=(0,1)\n)
          ],
          [__LINE__, qq(${spfx}\@${dollar}${name}_h${r}{${LQ}A${RQ},${LQ}B B${RQ}}\\n),
            qq(${spfx}\@${dollar}${name}_h${r}{${LQ}A${RQ},${LQ}B B${RQ}}=(111,222)\n)
          ],
        }
          #(['',''], ['$','r'])
          (['$','r'],['',''])
        ), #map [$dollar,$r]

        ( $] >= 5.022001 && $] <= 5.022001
            ?  (do{ state $warned = 0;
                    diag "\n\n** obj->method() tests disabled ** due to Perl v5.22.1 segfault!\n\n"
                     unless $warned++; ()
                  },())
            : (
               [__LINE__, qq(\$${name}_obj->meth ()), qq(\$${name}_obj->meth="meth_with_noargs" ()) ],
               [__LINE__, qq(\$${name}_obj->meth(42)), qq(\$${name}_obj->meth(42)=["methargs:",42]) ],
              )
        ),

        map({
          my ($dollar, $r, $arrow) = @$_;
          my $dolname_scalar = $dollar ? "\$$name" : $name;
          [__LINE__, qq(\$${dollar}${name}_h${r}${arrow}{\$${name}_a[\$two]}{e}\\n),
            qq(\$${dolname_scalar}_h${r}${arrow}{\$${name}_a[\$two]}{e}=999\n)
          ],
          [__LINE__, qq(\$${dollar}${name}_a${r}${arrow}[3]{C}{e}\\n),
            qq(\$${dolname_scalar}_a${r}${arrow}[3]{C}{e}=999\n)
          ],
          [__LINE__, qq(\$${dollar}${name}_a${r}${arrow}[3]{C}->{e}\\n),
            qq(\$${dolname_scalar}_a${r}${arrow}[3]{C}->{e}=999\n)
          ],
          [__LINE__, qq(\$${dollar}${name}_h${r}${arrow}{A}\\n),
            qq(\$${dolname_scalar}_h${r}${arrow}{A}=111\n)
          ],
        } (['$','r',''], ['','r','->'])
        ), #map [$dollar,$r,$arrow]
        }
        qw(closure sublexx toplex global subglobal 
           maskedglobal local A::B::C::ABC)
      ), #map $name
      } ('""', "''")
    ), #map ($LQ,$RQ)
  );
  for my $test (@dvis_tests) {
    my ($lno, $dvis_input, $expected, $skip_condition) = @$test;
    #warn "##^^^^^^^^^^^ lno=$lno dvis_input='$dvis_input' expected='$expected'\n";
    
    # FUTURE: wrap in subtest with plan skip_all => $skip_condition if skip_condition is true
    die "skip_condition not impl" if $skip_condition;

    { local $@;  # check for bad syntax first, to avoid uncontrolled die later
      # For some reason we can't catch exceptions from inside package DB.
      # undef is returned but $@ is not set
      # 3/5/22: The above comment may not longer be true; there might have been
      #  a bug where $@ was not saved properly.  
      #  BUT VERIFY b4 deleting this comment.
      my $ev = eval { "$dvis_input" };
      die "Bad test string:$dvis_input\nPerl can't interpolate it (lno=$lno)"
         .($@ ? ":\n  $@" : "\n")
        if $@ or ! defined $ev;
    }

    my sub checkspunct($$$) {
      my ($varname, $actual, $expecting) = @_;
      check "dvis('$dvis_input') lno $lno : $varname NOT PRESERVED : ",
            $actual//"<undef>", $expecting//"<undef>" ;
    }
    my sub checknpunct($$$) {
      my ($varname, $actual, $expecting) = @_;
      # N.B. check() compares as strings
      check "dvis('$dvis_input') lno $lno : $varname NOT PRESERVED : ",
            defined($actual) ? $actual+0 : "<undef>",
            defined($expecting) ? $expecting+0 : "<undef>" ;
    }

    for my $use_oo (0,1) {
      my $actual;
      my $dolatval = $@;
      eval { $@ = $dolatval;
        # Verify that special vars are preserved and don't affect Data::Dumper::Interp
        # (except if testing a punctuation var, then don't change it's value)

        my ($origAt,$origFs,$origBs,$origComma,$origBang,$origCarE,$origCarW)
          = ($@, $/, $\, $,, $!, $^E, $^W);

        # Don't change a value if being tested in $dvis_input
        my ($fakeAt,$fakeFs,$fakeBs,$fakeCom,$fakeBang,$fake_cE,$fake_cW)
          = ($dvis_input =~ /(?<!\\)\$@/    ? $origAt : "FakeAt",
             $dvis_input =~ /(?<!\\)\$\//   ? $origFs : "FakeFs",
             $dvis_input =~ /(?<!\\)\$\\\\/ ? $origBs : "FakeBs",
             $dvis_input =~ /(?<!\\)\$,/    ? $origComma : "FakeComma",
             $dvis_input =~ /(?<!\\)\$!/    ? $origBang : 6,
             $dvis_input =~ /(?<!\\)\$^E/   ? $origCarE : 6,  # $^E aliases $! on most OSs
             $dvis_input =~ /(?<!\\)\$^W/   ? $origCarW : 0); # $^W can only be 0 or 1

        ($@, $/, $\, $,, $!, $^E, $^W) 
          = ($fakeAt,$fakeFs,$fakeBs,$fakeCom,$fakeBang,$fake_cE,$fake_cW);

        $actual = $use_oo
           ? Data::Dumper::Interp->new()->dvis($dvis_input)
           : dvis($dvis_input);

        checkspunct('$@',  $@,   $fakeAt);
        checkspunct('$/',  $/,   $fakeFs);
        checkspunct('$\\', $\,   $fakeBs);
        checkspunct('$,',  $,,   $fakeCom);
        checknpunct('$!',  $!+0, $fakeBang);
        checknpunct('$^E', $^E+0,$fake_cE);
        checknpunct('$^W', $^W+0,$fake_cW);

        # Restore
        ($@, $/, $\, $,, $!, $^E, $^W)
          = ($origAt,$origFs,$origBs,$origComma,$origBang,$origCarE,$origCarW);
        $dolatval = $@;
      }; #// do{ $actual  = $@ };
      $actual = $@ if $@;
      $@ = $dolatval;

      checkeq_literal(
        "dvis (oo=$use_oo) lno $lno failed: input «"
                                              . show_white($dvis_input)."»",
        $expected,
        $actual);
    }

    for my $useqq (0, 1, "utf8", "unicode", "unicode:controlpic",
                   "unicode:qq", "unicode:qq=()", "qq",
                  ) {
      my $input = $expected.$dvis_input.'qqq@_(\(\))){\{\}\""'."'"; # gnarly
      # Now Data::Dumper (version 2.174) forces "double quoted" output
      # if there are any Unicode characters present.
      # So we can not test single-quoted mode in those cases
      next
        if !$useqq && $input =~ tr/\0-\377//c;
      my $exp = doquoting($input, $useqq);
      my $act = Data::Dumper::Interp->new()->Useqq($useqq)->vis($input);
      die "\n\nUseqq ",u($useqq)," bug:\n"
         ."     Input ".displaystr($input)."\n"
         ."  Expected ".displaystr($exp)."\n"
         ."       Got ".displaystr($act)."\n"
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
  no warnings 'once';
  die "Punct save/restore imbalance" if @Data::Dumper::save_stack != 0;
}
sub g($) {
  local $_ = 'SHOULD NEVER SEE THIS';
  goto &f;
}
confess "Non-zero CHILD_ERROR ($?)" if $? != 0;
&g(42,$toplex_ar);

#print "Tests passed.\n";
#say "stderrstring:$stderr_string";

ok(1, "The whole shebang");
done_testing();
exit 0;

# End Tester
