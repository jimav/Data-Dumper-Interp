# License: Public Domain or CC0
# See https://creativecommons.org/publicdomain/zero/1.0/
# The author, Jim Avera (jim.avera at gmail) has waived all copyright and
# related or neighboring rights to the content of this file.
# Attribution is requested but is not required.

use strict; use warnings  FATAL => 'all'; use feature qw/say/;
use feature qw/say state current_sub/;
use utf8;

package t_Utils;

require Exporter;
use parent 'Exporter';

our @EXPORT = qw/bug oops ok_with_lineno like_with_lineno
                 rawstr showstr showcontrols displaystr 
                 show_white show_empty_string
                 fmt_codestring timed_run
                 checkeq_literal check
                _check_end
                /;

our @EXPORT_OK = qw/$showstr_maxlen @quotes/;

use Test::More;
use Carp;

sub bug(@) { @_=("BUG:",@_); goto &Carp::confess }
sub oops(@) { @_=("Internal oops! ",@_); goto &Carp::confess }

sub show_empty_string(_) {
  $_[0] eq "" ? "<empty string>" : $_[0]
}

sub show_white(_) { # show whitespace which might not be noticed
  local $_ = shift;
  return "(Is undef)" unless defined;
  s/\t/<tab>/sg;
  s/( +)$/"<space>" x length($1)/seg; # only trailing spaces
  s/\n/<newline>\n/sg;
  show_empty_string $_
}

our $showstr_maxlen = 300;
our @quotes = ("«", "»");
#our @quotes = ("<<", ">>");
sub rawstr(_) { # just the characters in French Quotes (truncated)
  $quotes[0].(length($_[0])>$showstr_maxlen ? substr($_[0],0,$showstr_maxlen-3)."..." : $_[0]).$quotes[1]
}

# Show controls as single-charcter indicators like DDI's "controlpics",
# with the whole thing in French Quotes.  Truncate if huge.
sub showcontrols(_) {
  local $_ = shift;
  s/\n/\N{U+2424}/sg; # a special NL glyph
  s/[\x{00}-\x{1F}]/ chr( ord($&)+0x2400 ) /aseg;
  rawstr
}

# showstr(_) : Show controls as traditional \t \n etc. if possible
BEGIN{
  if (Cwd::abs_path(__FILE__) =~ /Data-Dumper-Interp/) {
    # we are being used to test Data::Dumper::Interp, so don't use it
    eval 'sub showstr(_) { showcontrols(shift) }';
  } else {
    use Data::Dumper::Interp;
    eval 'sub showstr(_) { visnew->Useqq("unicode")->vis(shift) }';
  }
  die $@ if $@;
}

# Show both the raw string in French Quotes, and with hex escapes
# so we can still see something useful in output from non-Unicode platforms.
sub displaystr($) {
  my ($input) = @_;
  return "undef" if ! defined($input);
  # Data::Dumper will show 'wide' characters as hex escapes
  my $dd = Data::Dumper->new([$input])->Useqq(1)->Terse(1)->Indent(0)->Dump;
  chomp $dd;
  if ($dd eq $input || $dd eq "\"$input\"") {
    # No special characters, so omit the hex-escaped form
    return rawstr($input)
  } else {
    return rawstr($input)."($dd)"
  }
}

sub fmt_codestring($;$) { # returns list of lines
  my ($str, $prefix) = @_;
  $prefix //= "line ";
  my $i; map{ sprintf "%s%2d: %s\n", $prefix,++$i,$_ } (split /\n/,$_[0]);
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

sub ok_with_lineno($;$) {
  my ($isok, $test_label) = @_;
  my $lno = (caller)[2];
  $test_label = ($test_label//"") . " (line $lno)";
  @_ = ( $isok, $test_label );
  goto &Test::More::ok;  # show caller's line number
}
sub like_with_lineno($$;$) {
  my ($got, $exp, $test_label) = @_;
  my $lno = (caller)[2];
  $test_label = ($test_label//"") . " (line $lno)";
  @_ = ( $got, $exp, $test_label );
  goto &Test::More::like;  # show caller's line number
}

sub _check_end($$$) {
  my ($errmsg, $test_label, $ok_only_if_failed) = @_;
  return
    if $ok_only_if_failed && !$errmsg;
  my $lno = (caller)[2];
  diag "**********\n${errmsg}***********\n" if $errmsg;
  @_ = ( !$errmsg, $test_label );
  goto &ok_with_lineno;
}

# Nicer alternative to check() when 'expected' is a literal string, not regex
sub checkeq_literal($$$) {
  my ($desc, $exp, $act) = @_;
  #confess "'exp' is not plain string in checkeq_literal" if ref($exp); #not re!
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
        ."${desc}\n"
        ."Expected:\n".displaystr($exp)."\n"
        ."Actual:\n".displaystr($act)."\n"
        # + for opening « or << in the displayed str
        .(" " x ($posn+length($quotes[0])))."^\n"
        .visFoldwidth()."\n" ) ;
  #goto &Carp::confess;
  Carp::confess(@_);
}

# Convert a literal "expected" string which contains things which are
# represented differently among versions of Perl and/or Data::Dumper
# into a regex which works with all versions.
# As of 1/1/23 the input string is expected to be what Perl v5.34 produces.
our $bs = '\\';  # a single backslash
sub expstr2re($) {
  local $_ = shift;
  confess "bug" if ref($_);
  unless (m#qr/|"::#) {
    return $_; # doesn't contain variable-representation items
  }
  # In \Q *string* \E the *string* may not end in a backslash because
  # it would be parsed as (\\)(E) instead of (\)(\E).
  # So change them to a unique token and later replace problematic
  # instances with ${bs} variable references.
  s/\\/<BS>/g;
  $_ = '\Q' . $_ . '\E';
  s#([\$\@\%])#\\E\\$1\\Q#g;

  if (m#qr/#) {
    # Canonical: qr/STUFF/MODIFIERS
    # Alternate: qr/STUFF/uMODIFIERS
    # Alternate: qr/(?^MODIFIERS:STUFF)/
    # Alternate: qr/(?^uMODIFIERS:STUFF)/
#say "#XX qr BEFORE: $_";
    s#qr/([^\/]+)/([msixpodualngcer]*)
     #\\E\(\\Qqr/$1/\\Eu?\\Q$2\\E|\\Qqr/(?^\\Eu?\\Q$2:$1)/\\E\)\\Q#xg
      or confess "Problem with qr/.../ in input string: $_";
#say "#XX qr AFTER : $_";
  }
  if (m#\{"([\w:]+).*"\}#) {
    # Canonical: fh=\*{"::\$fh"}  or  fh=\*{"Some::Pkg::\$fh"}
    #   which will be encoded above like ...\Qfh=<BS>*{"::<BS>\E\$\Qfh"}
    # Alt1     : fh=\*{"main::\$fh"}
    # Alt2     : fh=\*{'main::$fh'}  or  fh=\*{'main::$fh'} etc.
#say "#XX fh BEFORE: $_";
    s{(\w+)=<BS>\*\{"(::)<BS>([^"]+)"\}}
     {$1=<BS>*{\\E(?x: "(?:main::|::) \\Q<BS>$3"\\E | '(?:main::|::) \\Q$3'\\E )\\Q}}xg
    |
    s{(\w+)=<BS>\*\{"(\w[\w:]*::)<BS>([^"]+)"\}}
     {$1=<BS>*{\\E(?x: "\\Q$2<BS>$3"\\E | '\\Q$2$3'\\E )\\Q}}xg
    or
      confess "Problem with filehandle in input string <<$_>>";
#say "#XX fh AFTER : $_";
  }
  s/<BS>\\/\${bs}\\/g;
  s/<BS>/\\/g;
#say "#XX    FINAL : $_";

  my $saved_dollarat = $@;
  my $re = eval "qr{${_}}"; die "$@ " if $@;
  $@ = $saved_dollarat;
  $re
}

# check $test_desc, string_or_regex, result
sub check($$@) {
  my ($desc, $expected_arg, @actual) = @_;
  local $_;  # preserve $1 etc. for caller
  my @expected = ref($expected_arg) eq "ARRAY" ? @$expected_arg : ($expected_arg);
  confess "zero 'actual' results" if @actual==0;
  confess "ARE WE USING THIS FEATURE? (@actual)" if @actual != 1;
  confess "ARE WE USING THIS FEATURE? (@expected)" if @expected != 1;
  confess "\nTESTa FAILED: $desc\n"
         ."Expected ".scalar(@expected)." results, but got ".scalar(@actual).":\n"
         ."expected=(@expected)\n"
         ."actual=(@actual)\n"
         ."\$@=$@\n"
    if @expected != @actual;
  foreach my $i (0..$#actual) {
    my $actual = $actual[$i];
    my $expected = $expected[$i];
    if (!ref($expected)) {
      # Work around different Perl versions stringifying regexes differently
      $expected = expstr2re($expected);
    }
    if (ref($expected) eq "Regexp") {
      unless ($actual =~ $expected) {
        @_ = ( "\n**************************************\n"
              ."TESTb FAILED: ".$desc."\n"
              ."Expected (Regexp):\n".${expected}."<<end>>\n"
              ."Got:\n".displaystr($actual)."<<end>>\n"
              .visFoldwidth()."\n" ) ;
        Carp::confess(@_); #goto &Carp::confess;
      }
#say "###ACT $actual";
#say "###EXP $expected";
    } else {
      unless ($expected eq $actual) {
        @_ = ("TESTc FAILED: $desc", $expected, $actual);
        goto &checkeq_literal
      }
    }
  }
}

1;
