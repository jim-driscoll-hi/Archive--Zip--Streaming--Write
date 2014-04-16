package Archive::Zip::Streaming::Read;

# Copyright (c) 2014, Jim Driscoll
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this
# list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

use strict;
use warnings;
use bytes;
use Compress::Zlib;

my $SIZE_IN_DATA_DESCRIPTOR = 0b00000000_00001000;

my %pack_format_length;

=head1 NAME

Archive::Zip::Streaming::Read

=head1 DESCRIPTION

Support for unzipping data, stream-style. Should be largely compatible with Archive::Tar::Streaming::Read. Generally this will die() on error.

=head1 SYNOPSIS

    use Archive::Zip::Streaming::Read;
    my ($zsr) = Archive::Zip::Streaming::Read->new($fh);
    while(my $header = $zsr->read_header) {
        ($content, $header) = $zsr->read_data;
        # You could do something with it here...
    }
 
=cut

# _dos_d_t_to_ts($dos_date, $dos_time)
#
# Returns the UNIX timestamp corresponding to the given DOS date and time numbers.
sub _dos_d_t_to_ts {
    my ($dos_date, $dos_time) = @_;
    require Time::Local;
    return Time::Local::timelocal(
        ($dos_time & 0x1f) * 2,
        ($dos_time >> 5) & 0x3f,
        ($dos_time >> 11),
        $dos_date & 0x1f,
        (($dos_date >> 5) & 0xf) - 1,
        ($dos_date >> 9) + 1980 - 1900,
    );
}

# _pack_format_length($format)
#
# Does some quick trickery to work out exactly how long the data should be.
# This will be cached on the package because there SHOULD be very few formats used.
sub _pack_format_length {
    my ($format) = @_;
    if(not exists($pack_format_length{$format})) {
        (my $format_expanded = $format)=~s/Q/VV/g; # Expand Q which may not be natively supported
        $pack_format_length{$format} = length(pack($format_expanded));
    }
    return $pack_format_length{$format};
}

# _unpack_fake($format, $data)
#
# Simple wrapper for unpack() to reliably support "Q" format.
sub _unpack_fake {
    my ($format, $data) = @_;
    my @format_chunks = split(/(Q)/, $format);
    my @out;
    my $offset = 0;
    foreach my $chunk (@format_chunks) {
        if($chunk eq "Q") {
            my ($bottom, $top) = unpack("VV", substr($data, $offset));
            push(@out, $top * (2**32) + $bottom);
        } elsif(length $chunk) {
            push @out, unpack($chunk, substr($data, $offset));
        }
        $offset += _pack_format_length($chunk);
    }
    return @out;
}

# _unpack_walk($offset, $format, $data)
#
# Unpacks at $data (+$offset), returns the new offset followed by the results.
# Dies if there is not enough data left.
sub _unpack_walk {
    my ($offset, $format, $data) = @_;
    my $l = _pack_format_length($format);
    my $ld = length($data) - $offset;
    die "Not enough data to unpack: $ld < $l" if $ld < $l;
    return (
        $offset + $l,
        _unpack_fake($format, substr($data, $offset)),
    );
}

=head1 CLASS METHODS

=head2 new($fh)

Creates an object tied to a filehandle.

=cut

sub new {
    my ($class, $fh) = @_;
    return bless({
        _fh => $fh,
        _overflow => "",
    }, $class);
}

=head1 INSTANCE METHODS

=cut

# _read($length)
# _read($length, $length_is_implicit)
#
# Quick wrapper to die on short reads and return the read data (scalar).
#
# If $length_is_implicit is true, it will not die on a short read; you can use this when you don't know the length of the data.
sub _read {
    my ($self, $length, $length_is_implicit) = @_;
    if($length) {
        my $out = "";
        if(length($self->{_overflow})) {
            if(length($self->{_overflow}) >= $length) {
                return substr($self->{_overflow}, 0, $length, '');
            } else {
                $out .= $self->{_overflow};
                $length -= length($out);
                $self->{_overflow} = "";
            }
        }
        while( (my $l = ($length > 0xff_ff_ff_ff) ? 0xff_ff_ff_ff : $length ) ) {
            my $in_length = read($self->{_fh}, my $in, $l);
            die $! unless $in_length;
            $out .= $in;
            if($in_length < $l) {
                if($length_is_implicit) {
                    return $out;
                } else {
                    die "Short read: $in_length < $l" if($in_length < $l);
                }
            }
            $length -= $l;
        }
        return $out;
    } else {
        return "";
    }
}

# _read_packed($format)
#
# Reads some packed data.
sub _read_packed {
    my ($self, $format) = @_;
    return unpack($format, $self->_read(_pack_format_length($format)));
}

=head2 read_data()
 
Reads and returns the data referred to by the last header block; in array context this will be followed by a hashref of the updated header block (for example, this should contain a correct size!).
 
The data will be undef for directories.

This will return nothing in the case of an unknown compression method.
 
=cut

sub read_data {
    my ($self) = @_;
    my $header = $self->{_last_header};
    my %headers_out;
    if($header->{type} eq "-") {
        my $content;
        if($header->{compression_method} == 0) {
            # Store
            $content = $self->_read($header->{size});
        } elsif($header->{compression_method} == 8) {
            # DEFLATE
            my ($d, $status) = Compress::Zlib::inflateInit(
                -WindowBits => -(MAX_WBITS),
            );
            if($status) {
                die "Inflate error: $status";
            }
            my $in;
            while( ( $in = $self->_read(4096, 1) ) ) { # Example size
                ($content, $status) = $d->inflate(\$in);
                if($status == Z_OK) {
                    # Do nothing. Just loop.
                } elsif($status == Z_STREAM_END) {
                    last;
                } else {
                    die "Inflate error: $status ".$d->msg;
                }
            }
            $self->{_overflow} = $in . $self->{_overflow};
        } else {
            warn "Unknown compression method: $header->{compression_method}";
            return;
        }
        if($header->{size_on_read}) {
            my $format = $header->{zip64} ? "VVQQ" : "VVVV";
            my ($signature, $crc32, $compressed_size, $uncompressed_size) = _unpack_fake(
                $format,
                $self->_read(_pack_format_length($format))
            );
            if($signature == 0x08074b50) {
                %headers_out = (
                    %headers_out,
                    checksum => $crc32,
                    size => $uncompressed_size,
                );
            } else {
                die "Unknown data descriptor signature: $signature";
            }
        }
        return wantarray ? ($content, {%$header, %headers_out}): $content;
    } elsif($header->{type} eq "d") {
        return wantarray ? (undef, {%$header, %headers_out}): undef;
    } else {
        die "Unknown type $header->{type}";
    }
}

=head2 read_header()

Reads the next header and returns it. Fields included are:

=over
 
=item checksum
 
The CRC32 checksum for the uncompressed data. Under some circumstances (generally with compressed data) this won't be set. Not applicable to directories.
 
=item compression_method
 
The compression method number. This is internal to the zip format, but you could expect values 0 (uncompressed) and 8 (DEFLATE).
 
=item filename
 
The name of the file.
 
=item gid
 
The GID of the file, if known and set.

=item linkpath
 
Not set, only present for compatibility.

=item mode
 
Not set at this time, as the data is only stored in the central directory.

=item mtime

The modification time (timestamp).

=item path

As filename above.

=item size

The size of the uncompressed data, in bytes. Under some circumstances (generally with compressed data) this won't be set.

=item size_on_read

True if you need to read the item to get its size, see size above.

=item type

The UNIX type letter. Should be "-" (file) or "d" (directory).

=item uid

The UID of the file's owner, if known and set.
 
=item zip64

True if this item is stored in zip64 format.

=back
 
If this encounters any header block with an unknown signature, it will assume that it has reached the end and return.

=cut

sub read_header {
    my ($self) = @_;
    my (
        $local_file_header_signature,
        $version_needed,
        $bit_flag,
        $compression_method_n,
        $dos_time,
        $dos_date,
        $crc32,
        $compressed_size,
        $uncompressed_size,
        $filename_length,
        $extra_field_length
    ) = $self->_read_packed("VSSSSSVVVSS");
    return unless $local_file_header_signature == 0x04034b50;
    die "Zip spec version too high ($version_needed > 45)" if $version_needed > 45;
    
    my $filename = $self->_read($filename_length);
    my %extra_fields;

    if($extra_field_length) {
        my $extra_fields_packed = $self->_read($extra_field_length);
        my $header_length = _pack_format_length("SS");
        
        my $efp_len;
        while(($efp_len = length $extra_fields_packed) >= $header_length) {
            my ($type, $length) = unpack("SS", $extra_fields_packed);
            die "Invalid headers: $length + $header_length > $efp_len" if($length + $header_length > $efp_len);
            my ($data) = substr($extra_fields_packed, $header_length, $length);
            $extra_fields{$type} = $data;
            $extra_fields_packed = substr($extra_fields_packed, $header_length + $length);
        }
        if(length $extra_fields_packed) {
            die "Invalid headers: trailling data of length".length($extra_fields_packed);
        }
    }
    
    my $zip64;
    if($version_needed >= 45 and $compressed_size == 0xff_ff_ff_ff and $uncompressed_size == 0xff_ff_ff_ff) {
        # Zip64 mode!
        $zip64 = 1;
        my $zip64_detail = $extra_fields{0x0001};
        die "Zip64 format without length data" unless $zip64_detail;
        die "Zip64 header length invalid" unless length($zip64_detail) > _pack_format_length("QQ");
        ($uncompressed_size, $compressed_size) = _unpack_fake("QQ", $zip64_detail);
    }
    my ($uid, $gid);
    if($extra_fields{0x7875}) {
        # Latest UNIX ownership
        my $uid_gid_detail = $extra_fields{0x7875};
        my $offset = 0;
        ($offset, my $version) = _unpack_walk($offset, "C", $uid_gid_detail);
        if($version == 1) {
            my %length_to_unpack = (
                4 => "N",
            );
            ($offset, my $uid_length) = _unpack_walk($offset, "C", $uid_gid_detail);
            if($length_to_unpack{$uid_length}) {
                ($offset, $uid) = _unpack_walk($offset, $length_to_unpack{$uid_length}, $uid_gid_detail);
            } else {
                warn "Can't handle UID length $uid_length";
                $offset += $uid_length;
            }
            ($offset, my $gid_length) = _unpack_walk($offset, "C", $uid_gid_detail);
            if($length_to_unpack{$gid_length}) {
                ($offset, $gid) = _unpack_walk($offset, $length_to_unpack{$gid_length}, $uid_gid_detail);
            } else {
                warn "Can't handle GID length $uid_length";
                $offset += $gid_length;
            }
        }
    }
    
    my ($mtime, $atime, $ctime);
    if($extra_fields{0x5455}) {
        # UNIX file timestamps.
        my $unix_timestamp_detail = $extra_fields{0x5455};
        my $offset = 0;
        ($offset, my $time_map_n) = _unpack_walk($offset, "C", $unix_timestamp_detail);
        if($time_map_n & 0x80) {
            ($offset, $mtime) = _unpack_walk($offset, "V", $unix_timestamp_detail);
        }
        if($time_map_n & 0x40) {
            ($offset, $atime) = _unpack_walk($offset, "V", $unix_timestamp_detail);
        }
        if($time_map_n & 0x20) {
            ($offset, $ctime) = _unpack_walk($offset, "V", $unix_timestamp_detail);
        }
    }
    
    my ($type, $filename_short);
    if($filename=~m{(.*)/$}) {
        ($type, $filename_short) = ("d", $1);
    } else {
        ($type, $filename_short) = ("-", $filename);
    }
    my %header_parsed = (
        atime => $atime,
        checksum => ($bit_flag & $SIZE_IN_DATA_DESCRIPTOR) ? undef : $crc32,
        compression_method => $compression_method_n,
        ctime => $ctime,
        filename => $filename_short,
        gid => $gid,
        linkpath => undef, # Only present for compat.
        mode => undef, # Not available until later
        mtime => defined($mtime) ? $mtime : _dos_d_t_to_ts($dos_date, $dos_time),
        path => $filename_short,
        size => ($bit_flag & $SIZE_IN_DATA_DESCRIPTOR) ? undef : $uncompressed_size,
        size_on_read => $bit_flag & $SIZE_IN_DATA_DESCRIPTOR,
        type => $type,
        uid => $uid,
        zip64 => $zip64,
    );
    
    $self->{_last_header} = \%header_parsed;
    
    return wantarray ? %header_parsed : \%header_parsed;
}

=head1 NOTES
 
=head2 A note on DEFLATE
 
DEFLATE is the common compression format used in zip files, it operates in blocks however the blocks are not of determinate length (bar a certain minimum size). Because of this, and the fact that the zip format does not pad its data, read_data will almost always over-read somewhat. When this happens the excess data will be retained and drained before resuming reads from the underlying filehandle.

This also means you simply can't skip a body chunk: you need to read it to determine how long it is. If you wanted to skip it, a non-streaming zip module would work well.
 
=cut

1;