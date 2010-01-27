#!/usr/bin/perl

use constant VERSION => "0.1";

#
# this is the backend postprocessing for the chaosvpn client
#
#
# normal client users do not need this!
#
#
# to setup your own backend you need to install a bunch of additional
# debian packages, create your own rsa backend secret key, and change
# the paths below.
#
# create secret rsa key:
# openssl genrsa -out privkey.pem 4096
#
# export public key part:
# openssl rsa -in privkey.pem -pubout -out pubkey.pem
#


# v0.01 20100127 haegar@ccc.de
# - first revision, based on old chaosvpn perl client

use strict;
use Data::Dumper;
use Archive::Ar;		# libarchive-ar-perl
use Compress::Zlib;		# libcompress-zlib-perl
use Crypt::OpenSSL::Random;     # libcrypt-openssl-random-perl
use Crypt::OpenSSL::RSA - RSA;  # libcrypt-openssl-rsa-perl
use Crypt::CBC;			# libcrypt-cbc-perl
use Crypt::Rijndael;		# libcrypt-rijndael-perl / AES

$| = 1;

my $destdir = "/webroot/www.vpn.hamburg.ccc.de/chaosvpn-data";
my $cleartextconfig = "/webroot/www.vpn.hamburg.ccc.de/tinc-chaosvpn.txt";
my $signkey = "/home/haegar/chaosvpn/clearprivkey.pem";
my $signpubkey = "/home/haegar/chaosvpn/pubkey.pem";


# --- no changes needed below for simple usage ---


my $fileformat_version = "3";
# increase this number for every incompatible file format change

my $config = read_file_into_string("<$cleartextconfig") || die "config read error\n";

my $sign_secret_key = read_file_into_string("<$signkey") || die "signkey read error\n";
my $sign_public_key = read_file_into_string("<$signpubkey") || die "signpubkey read error\n";

openssl_init();


# first: compatibility for old sign script:
my $signature = rsa_sign_data($config, $sign_secret_key);
write_string_into_file(">$cleartextconfig.sig", $signature);


# second: new sign and encrypt
my $peers = parse_config($config);
if ($peers) {
	eval {
		create_config($peers);
	};
	if ($@) {
		warn $@;
	}
} else {
	die "read and parse failed!\n";
}

print "\nfinished.\n";
exit(0);

sub parse_config($)
{
	my ($answer) = @_;
	my $peers = {};

	my $current_peer = undef;
	my $peer = {};
	my $in_key = 0;
 
	foreach (split(/\n/, $answer)) {
		#print "debug: $_\n";

		s/\#.*$//;

		if (/^\s*\[(.*?)\]\s*$/) {
			if ($current_peer) {
				$peers->{$current_peer} = $peer;
			}
			$peer = {
				"use-tcp-only"	=> 0,
				"hidden"	=> 0,
				"silent"	=> 0,
				"port"		=> 655,
				};
			$current_peer = $1;
			$current_peer = undef unless ($current_peer =~ /^[a-z0-9_\-]+$/i);
			$in_key = 0;
		} elsif ($current_peer) {
			if ($in_key) {
				$peer->{pubkey} .= $_;
				$peer->{pubkey} .= "\n";

				$in_key = 0
					if (/^-----END RSA PUBLIC KEY-----/);
			} elsif (/^\s*gatewayhost=(.*)$\s*/i) {
				$peer->{gatewayhost} = $1;
			} elsif (/^\s*owner=(.*)$\s*/i) {
				$peer->{owner} = $1;
			} elsif (/^\s*use-tcp-only=(.*)$\s*/i) {
				$peer->{"use-tcp-only"} = $1;
			} elsif (/^\s*network=(.*)\s*$/i) {
				push @{$peer->{networks}}, $1;
			} elsif (/^\s*network6=(.*)\s*$/i) {
				push @{$peer->{networks6}}, $1;
			} elsif (/^\s*route_network=(.*)\s*$/i) {
				push @{$peer->{route_networks}}, $1;
			} elsif (/^\s*route_network6=(.*)\s*$/i) {
				push @{$peer->{route_networks6}}, $1;
			} elsif (/^\s*hidden=(.*)\s*$/i) {
				$peer->{hidden} = $1;
			} elsif (/^\s*silent=(.*)\s*$/i) {
				$peer->{silent} = $1;
			} elsif (/^\s*port=(.*)\s*$/i) {
				$peer->{port} = $1;
			} elsif (/^\s*indirectdata=(.*)\s*$/i) {
				$peer->{indirect_data} = $1;
			} elsif (/^-----BEGIN RSA PUBLIC KEY-----/) {
				$in_key = 1;
				$peer->{pubkey} = $_ . "\n";
			}
		} elsif (/^\s*$/ || /^\s*\#/) {
			# ignore empty lines or comments
		} else {
			warn "unknown line: $_\n";
		}
	}

	# den letzten, noch offenen, peer auch in der struktur verankern
	if ($current_peer) {
		$peers->{$current_peer} = $peer;
	}

	return $peers;
}


sub create_config($)
{
	my ($peers) = @_;

	if (-e "$destdir.new") {
		system("rm", "-r", "$destdir.new") && die;
	}
	if (-e "$destdir.old") {
		system("rm", "-r", "$destdir.old") && die;
	}

	system("mkdir", "-p", "$destdir.new") && die;

	chdir("$destdir.new") || die "chdir to $destdir.new failed: $!\n";

	open(INDEX, ">index.html") || die "create index.html failed\n";
	print INDEX "Nothing here to view.\n";
	close(INDEX);
	
	PEERS: foreach my $id (sort(keys %$peers)) {
		my $peer = $peers->{$id};

		my $ar = new Archive::Ar();

		print "\npeer: $id\n";
		#print Dumper($peer);

		$ar->add_data("chaosvpn-version", $fileformat_version);
                		
		my $aeskey = Crypt::OpenSSL::Random::random_bytes(32);
		my $aesiv = Crypt::OpenSSL::Random::random_bytes(16);
		
		#write_string_into_file(">cleartext", $config) || die "write cleartext for $id failed: $!\n";
		#write_string_into_file(">pubkey.pem", $peer->{pubkey}) || die "write pubkey for $id failed: $!\n";

		#print "  add cleartext...";
		#$ar->add_data("cleartext", $config);
		#print ".\n";

		print "  compress config...";
		my $compressed_config = Compress::Zlib::compress($config, 9);
		print ".\n";
		
                print "  encrypt config...";
                my $encrypted_config = aes_encrypt($compressed_config, $aeskey, $aesiv);
                $ar->add_data("encrypted", $encrypted_config);
                print ".\n";
            
		print "  sign cleartext...";
		#system("/usr/bin/openssl", "dgst",
		#	"-sha512",
		#	"-sign", $signkey,
		#	"-out", "./signature",
		#	"./cleartext")
		#	&& die "digest for $id failed\n";
		my $signature = rsa_sign_data($config, $sign_secret_key);
		#write_string_into_file(">signature", $signature);
		$signature = aes_encrypt($signature, $aeskey, $aesiv);
		$ar->add_data("signature", $signature);
		print ".\n";

		print "  rsa part...";
		#my $rsa_cleartext =
		#  chr(length($aeskey)) . # length of aes key in bytes, 0-255
		#  chr(length($aesiv)) .	 # length of aes iv in bytes, 0-255
		#  $aeskey,
		#  $aesiv;
		my $rsa_cleartext = pack("CCA*A*",
		        length($aeskey), length($aesiv),
		        $aeskey,
		        $aesiv);
                my $rsa_enc = rsa_encrypt($rsa_cleartext, $peer->{pubkey});
                $ar->add_data("rsa", $rsa_enc);
		print ".\n";
		
		#system("/usr/bin/openssl", "dgst",
		#	"-sha512",
		#	"-verify", $signpubkey,
		#	"-signature", "./signature",
		#	"./cleartext")
		#	&& die "verify signature for $id failed\n";

		print "  create $id.dat...";
		#system("/usr/bin/ar", "-r",
		#	"./$id.dat",
		#	"./cleartext", "./signature")
		#	&& die "ar for $id failed\n";
		$ar->write("./$id.dat");
		print ".\n";
		
		#unlink("./cleartext");
		#unlink("./signature");
	}

	chdir("/") || die "chdir / failed: $!\n";

	if (-d "$destdir") {
		rename("$destdir", "$destdir.old") || die;
	}
	rename("$destdir.new", "$destdir") || die;

	return 1;
}

sub openssl_init()
{
  if (open(URANDOM, "</dev/urandom")) {
    my $buffer = "";
    read URANDOM, $buffer, 512;
    close(URANDOM);
    if (defined($buffer) && ($buffer ne "")) {
      Crypt::OpenSSL::Random::random_seed($buffer);
    }
  }  
  Crypt::OpenSSL::RSA->import_random_seed();
}

sub rsa_sign_data($$)
{
  my ($data, $privkey) = @_;
  
  my $rsa_priv = Crypt::OpenSSL::RSA->new_private_key($privkey);
  $rsa_priv->use_sha512_hash();
  return $rsa_priv->sign($data);
}

sub rsa_verify_data($$$)
{
  my ($data, $signature, $pubkey) = @_;
  
  my $rsa_pub = Crypt::OpenSSL::RSA->new_public_key($pubkey);
  $rsa_pub->use_sha512_hash();
  return $rsa_pub->verify($data, $signature);
}

sub rsa_encrypt($$)
{
  my ($data, $pubkey) = @_;
  
  my $rsa_pub = Crypt::OpenSSL::RSA->new_public_key($pubkey);
  $rsa_pub->use_pkcs1_oaep_padding();
  return $rsa_pub->encrypt($data);
}

sub aes_encrypt($$$)
{
  my ($data, $aeskey, $aesiv) = @_;
  
  my $cipher = Crypt::CBC->new(
    -cipher		=> "Crypt::Rijndael",
    -padding		=> "standard",
    -header		=> "none",
    -literal_key	=> 1,
    -key		=> $aeskey,
    -iv			=> $aesiv,
    -blocksize		=> 16,
    );
  return $cipher->encrypt($data);
}

sub aes_decrypt($$$)
{
  my ($ciphertext, $aeskey, $aesiv) = @_;
  
  my $cipher = Crypt::CBC->new(
    -cipher		=> "Crypt::Rijndael",
    -padding		=> "standard",
    -header		=> "none",
    -literal_key	=> 1,
    -key		=> $aeskey,
    -iv			=> $aesiv,
    -blocksize		=> 16,
    );
  return $cipher->decrypt($ciphertext);
}

sub write_string_into_file
{
	my $fname = shift;
	$fname && open(__STRING, $fname) or return undef;
	for (my $i = 0; $i < @_; $i++) {
		if (ref($_[$i]) eq "SCALAR") {
			print __STRING ${$_[$i]} || return undef;
		} else {
			print __STRING $_[$i] || return undef;
		}
	}
	close(__STRING) || return undef;
	return 1;
}

sub read_file_into_string($)
{
        my $name = shift;
	my $result;

        return undef unless defined $name && $name;
        return undef unless open(__STRING, "$name");

        local $/=undef;
        $result = <__STRING>;
        close(__STRING);

	if ((!defined $result) && (!$!))
	{
		# 0 byte file - return empty string but no undef
		return "";
	}

        return $result;
}

sub tohex($)
{
  my ($in) = @_;
  my $out = "";
  my $c = 0;
  while ($c < length($in)) {
    $out .= sprintf("%02x", ord(substr($in, $c, 1)));
    $c++;
  }
  return $out;
}
