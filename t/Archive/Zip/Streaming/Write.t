use strict;
use warnings;

use Test::More tests => 3;
BEGIN { use_ok "Archive::Zip::Streaming::Write" };

local $ENV{PATH}="/bin:/usr/bin";
open(my $test_out, "|-", "grep", "-q", ".");

my $zs = new_ok "Archive::Zip::Streaming::Write" => [$test_out];

$zs->add_directory(
  "foo/",
  time,
  time,
  time,
  0755,
  -1,
  -1
);
$zs->add_file(
  "foo/bar",
  "test",
  time,
  time,
  time,
  0755,
  -1,
  -1,
  4
);
$zs->close;

subtest "Full zip test" => sub {
  use File::Temp qw/tempfile/;
  chomp(my @contents = qx(find *));
  my ($fh, $zip_filename) = tempfile();
  require Archive::Zip::Streaming::Write;
  my $zs = Archive::Zip::Streaming::Write->new($fh);

  foreach my $filename (@contents) {
    my @s = stat($filename);
    my ($atime, $mtime, $ctime, $mode, $uid, $gid) = @s[8,9,10,2,4,5];
    if(-f $filename) {
      if(open(F, "<", $filename)) {
        local $/=undef;
        my $content=<F>;
        close F;
        $zs->add_file($filename, $content, $atime, $mtime, $ctime, $mode, $uid, $gid);
      }
    } elsif(-d $filename) {
      $zs->add_directory($filename, $atime, $mtime, $ctime, $mode, $uid, $gid);
    }
  }
  $zs->close();
  if(-t STDERR) {
    open(STDOUT, ">&", \*STDERR);
  } else {
    open(STDOUT, ">", "/dev/null");
  }
  my $rv = system("unzip", "-l", $zip_filename);
  unlink($zip_filename);
  ok($rv == 0, "Zip test: accepted");
};

done_testing();
