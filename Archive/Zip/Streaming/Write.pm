package Archive::Zip::Streaming::Write;
use strict;
use warnings;

# Copyright (c) 2011, Heart Internet Ltd
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of the organization nor the
#       names of its contributors may be used to endorse or promote products
#       derived from this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

require Archive::Zip::Build;

use version; our $VERSION = version->declare("v0.1.1");

=head1 NAME

Archive::Zip::Streaming::Write

=head1 DESCRIPTION

A thin wrapper around Archive::Zip::Build to stream actual zip files rather than
just zip data.

Streams data OUT only.

=head1 SYNOPSIS

  unlink("test.zip");
  chomp(my @contents = qx(find *));
  open(my $fh, ">", "test.zip") or die $!;
  require Archive::Zip::Streaming::Write;
  my $zs = new Archive::Zip::Streaming::Write($fh);

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

=head1 METHODS

=head2 new($filehandle, \%options)

Prepares the object, which will use $filehandle to write.

Options will be passed to Archive::Zip::Build, possibly with some exceptions.

=cut

sub new {
  my ($class, $filehandle, $options) = @_;
  $options||={};
  my $self = {
    fh=>$filehandle,
    mz=>new Archive::Zip::Build($filehandle, $options),
  };
  return bless($self, $class);
}

=head2 add_directory($filename, $atime, $mtime, $ctime, $mode, $uid, $gid)

=head2 add_directory($filename, $atime, $mtime, $ctime, $mode)

Adds a directory to the zip file. $uid and $gid are optional; $mode is expected
to just be the permissions (as a number, eg. 0777 rather than 777 - use oct() if
you need to!). $mtime is REQUIRED.

=cut

sub add_directory {
  my ($self, $filename, $atime, $mtime, $ctime, $mode, $uid, $gid) = @_;
  my $full_mode = $mode|oct(40000);
  my @extra_fields_local;
  if(defined $uid) {
    push @extra_fields_local, (
      pack("S", 0x7875)=>pack("CCNCN", 1, 4, $uid, 4, $gid), # Newest UNIX format
    );
  }
  $self->{mz}->print_item(
    Name=>$filename."/",
    Time=>$mtime,
    ExtAttr=>$full_mode<<16,
    exTime => [$atime, $mtime, $ctime],
    Method => 'store',
    ExtraFieldLocal=>\@extra_fields_local,
  );
  # That's it! No more work needed.
}

=head2 add_file($filename, $content, $atime, $mtime, $ctime, $mode, $uid, $gid, $size)

=head2 add_file($filename, $content, $atime, $mtime, $ctime, $mode, $uid, $gid)

=head2 add_file($filename, $content, $atime, $mtime, $ctime, $mode)

Adds a file to the zip output. As add_directory() above except that you also
provide file contents.

This will guess some cases where compression is not appropriate from the filename.

If a file is of zero size, you should set $content to the empty string ("").
This is particularly appropriate for special files, eg. device nodes.

Standard symlink protocol in zip files is that you follow it, but if you provide
a symlink $mode then $content will be presumed to contain the path which it is
a link to, NOT the content of the destination file.

=cut

sub add_file {
  my ($self, $filename, $content, $atime, $mtime, $ctime, $mode, $uid, $gid, $size) = @_;
  my $full_mode = $mode|oct(100000);
  my @extra_fields_local;
  if(defined $uid) {
    push @extra_fields_local, (
      pack("S", 0x7875)=>pack("CCNCN", 1, 4, $uid, 4, $gid), # Newest UNIX format
    );
  }
  my $method = 'deflate';

  if(not(defined $size) and not(ref $content)) {
    $size=length($content);
  }
  # Skip deflation for several types.
  # .swf compresses ok
  if($filename=~/\.(?: zip | gz | tgz | png | gif | jpg | jpeg | jpe | wmv | wma | mp3 | aac | mp4 | mp2 | ogg | bz2 | fla | flv )$/x) {
    $method = 'store';
    if(defined($size) and $size > (2**31)-1) {
      # huge files might need this to stream continuously
      $method = 'deflate';
    }
  } elsif(defined($size) and $size < 80) {
    $method = 'store';
  }
  $self->{mz}->print_item(
    Name=>$filename,
    Time=>$mtime,
    ExtAttr=>$full_mode<<16,
    exTime => [$atime, $mtime, $ctime],
    Method => $method,
    ExtraFieldLocal=>\@extra_fields_local,
    content=>$content,
    Size=>$size,
  );
}

=head2 close()

Closes the zip stream.

=cut

sub close {
  my ($self) = @_;
  $self->{mz}->close() if $self->{mz};
  $self->{mz} = undef;
}

=head1 NOTES

No DESTROY here, because that can be dangerous.

=cut

1;
