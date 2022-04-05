#!/usr/bin/perl
use strict; use warnings  FATAL => 'all'; use feature qw(state say); use utf8;
use open IO => ':locale';
select STDERR; $|=1; select STDOUT; $|=1;
use Carp;
use POSIX qw(INT_MAX);
use Math::BigRat ();
use Math::BigInt ();
use Math::BigFloat ();

use Test::More;

use Data::Dumper::Interp;

my $initial_seed;
my $time_limit = 3;  # seconds

while (@ARGV) {
  if ($ARGV[0] =~ /^-s/) { shift; $initial_seed = shift // die }
  elsif ($ARGV[0] =~ /^-t/) { shift; $time_limit = shift // die }
  else { die "Unrecognized arg $ARGV[0]" }
}

if (defined $initial_seed) {
  $initial_seed = srand($initial_seed);
} else {
  $initial_seed = srand();
}
diag "Initial random seed is $initial_seed";


$Data::Dumper::Interp::Foldwidth = 12;
#$Data::Dumper::Interp::Useqq = "utf8:controlpics";
$Data::Dumper::Interp::Useqq = "1"; # more evalable
$Data::Dumper::Interp::_dbmaxlen = INT_MAX;

sub gen_hash($);
sub gen_list($);
sub gen_item();

my $maxlevel = 10;
my $level = 0;
our ($globalA, $globalB) = (42,undef);
my @saved_items;
sub gen_item() {
  return undef if $level > $maxlevel;
  ++$level;
  my $r;
  my $kind = int(rand(1+13));
  if    ($kind == 0) { $r = int(rand(50)); $r = int($r) if $r > 25; } #number
  elsif ($kind == 1) { # bignum
    my $subkind = int(rand(1+4));
    if    ($subkind == 0) { $r = Math::BigInt->new( int(rand(25)) ) }
    elsif ($subkind == 1) { $r = Math::BigFloat->new( rand(25) ) }
    elsif ($subkind == 2) { $r = Math::BigRat->new(42, 43) }
    elsif ($subkind == 3) { $r = Math::BigRat->new(Math::BigInt->new(int(rand(25))), 43) }
  }
  elsif ($kind == 2) { $r = gen_list(int(rand(25))) }
  elsif ($kind == 3) { $r = gen_hash(int(rand(25))) }
  elsif ($kind == 4) { $r = \gen_item() }
  elsif ($kind == 5) { $r = \\gen_item() }
  elsif ($kind == 6) { $r = \\\gen_item() }
  elsif ($kind == 7) { $r = "b" x int(rand(1+13)) } # bareword string
  elsif ($kind == 8) { $r = " y \N{U+2650} " x int(rand(1+3)) } # complicated string
  elsif ($kind == 9) { $r = undef }
  elsif ($kind == 10) { $r = "" }
  elsif ($kind == 11) { $r = 0 }
  elsif ($kind == 12) { $r = \$globalA }
  elsif ($kind == 13) { $r = @saved_items ? $saved_items[int rand($#saved_items+1)] : \$globalA } # self-references
  else { die }
  --$level;
  push @saved_items, $r;
  $r
}
sub gen_list($) {
  my $count = shift;
  [ map { gen_item() } (1..$count) ]
}
sub gen_hashkey() {
  my $kind = int(rand(1+3));
  if ($kind == 0) { return "x" x int(rand(15)) }   # bareword
  if ($kind == 1) { return " x " x int(rand(10)) } # string with spaces
  if ($kind == 2) { return int(rand(INT_MAX)) }    # integer
  if ($kind == 3) { return     rand(INT_MAX)  }    # float
  die
}
sub gen_hash($) {
  my $pair_count = shift;
  map { gen_hashkey() => gen_item() } (1..$pair_count)
}

# See if anything hits an assertion crash
my $start_time = time;
my $iter = 0;
while (time < $start_time+$time_limit) {
  # Do several iterations between OS calls to get current time
  for (0..49) {
    ++$iter;
    #$Data::Dumper::Interp::Debug = 1 if $iter==21;
    @saved_items = ();
    my $item = gen_item();
    my $r; eval { $r = vis $item };
    if ($@) {
      die "Iter $iter:\n$@\n\n", Data::Dumper->new([$item],["item"])->Dump,"\nFailed on iter $iter. initial_seed=$initial_seed  len(exmsg)=",length($@);
    }
    #diag "Iter $iter : vis result length = ",length($r);
  }
} 
ok(1, "Stopped after time limit expired ($time_limit seconds).  $iter iterations completed.");

done_testing();

exit 0;
