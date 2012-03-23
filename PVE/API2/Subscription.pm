package PVE::API2::Subscription;

use strict;
use warnings;
use Digest::MD5 qw(md5_hex md5_base64);
use MIME::Base64;
use HTTP::Request;
use LWP::UserAgent;
use JSON; 

use PVE::Tools;
use PVE::Exception qw(raise_param_exc);
use PVE::INotify;
use PVE::Cluster qw (cfs_read_file cfs_write_file);
use PVE::AccessControl;
use PVE::Storage;
use PVE::JSONSchema qw(get_standard_option);

use PVE::SafeSyslog;

use PVE::API2Tools;
use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

PVE::INotify::register_file('subscription', "/etc/pve-subscription",
			    \&read_etc_pve_subscription,
			    \&write_etc_pve_subscription);

# How long the local key is valid for in between remote checks
my $localkeydays = 15; 
# How many days to allow after local key expiry before blocking 
# access if connection cannot be made
my $allowcheckfaildays = 5;

my $shared_key_data = "kjfdlskfhiuewhfk947368";
my $hwaddress;

sub get_hwaddress {
    
    return $hwaddress if defined ($hwaddress);

    my $fn = '/etc/ssh/ssh_host_rsa_key.pub';
    my $sshkey = PVE::Tools::file_get_contents($fn);
    $hwaddress = uc(md5_hex($sshkey));

    return $hwaddress;
}

my $hwsockets;

sub get_sockets {
    return $hwsockets if $hwsockets;

    my $fh = IO::File->new ('/proc/cpuinfo', "r") ||
	die "can't read cpu info - $!\n";

    my $sockets = 0;
    while (defined(my $line = <$fh>)) {
	if ($line =~ m/^physical id\s*:\s*(\d+)\s*$/i) {
	    my $sid = $1 + 1;
	    $sockets = $sid if $sid > $sockets;
	}
    }

    close($fh);

    die "unable to get socket count\n" if !$sockets;

    $hwsockets = $sockets;

    return $hwsockets;
}

sub parse_key {
    my ($key) = @_;

    if ($key =~ m/^pve([124])([cbsp])-[0-9a-f]{10}$/) {
	return wantarray ? ($1, $2) : $1; # number of sockets, type
    }
    return undef;
}

sub check_fields {
    my ($info, $server_id, $req_sockets) = @_;

    foreach my $f (qw(status checktime key)) {
	if (!$info->{$f}) {
	    die "Missing field '$f'\n";
	}
    }

    my $sockets = parse_key($info->{key});
    if (!$sockets) {
	die "Wrong subscription key format\n";
    }
    if ($sockets < $req_sockets) {
	die "wrong number of sockets ($sockets < $req_sockets)\n";
    }

    if ($info->{checktime} > time()) {
	die "Last check time in future.\n";
    }

    return undef if $info->{status} ne 'Active';

    foreach my $f (qw(validdomain productname regdate nextduedate)) {
	if (!$info->{$f}) {
	    die "Missing field '$f'\n";
	}
    }

    my $found;
    foreach my $dom (split(/,/, $info->{validdomain})) {
	if ($dom eq $server_id) {
	    $found = 1;
	    last;
	}
    }
    die "Server ID does not match\n" if !$found;

    return undef;
}

sub read_etc_pve_subscription {
    my ($filename, $fh) = @_;

    my $info = { status => 'Invalid' };

    my $key = <$fh>; # first line is the key
    chomp $key;
    die "Wrong subscription key format\n" if !parse_key($key);

    my $csum = <$fh>; # second line is a checksum

    $info->{key} = $key;

    my $data = '';
    while (defined(my $line = <$fh>)) {
	$data .= $line;
    }

    if ($csum && $data) {

	chomp $csum;
    
	my $localinfo = {};

	eval {
	    my $json_text = decode_base64($data);
	    $localinfo = decode_json($json_text);
	    my $newcsum = md5_base64($localinfo->{checktime} . $data . $shared_key_data);
	    die "checksum failure\n" if $csum ne $newcsum;

	    my $req_sockets = get_sockets();
	    my $server_id = get_hwaddress();

	    check_fields($localinfo, $server_id, $req_sockets);

	    my $age = time() -  $localinfo->{checktime};

	    my $maxage = ($localkeydays + $allowcheckfaildays)*60*60*24;
	    if ($localinfo->{status} eq 'Active' && $age > $maxage) {
		$localinfo->{status} = 'Invalid';
		$localinfo->{message} = "subscription info too old";
	    }
	};
	if (my $err = $@) {
	    warn $err;
	} else {
	    $info = $localinfo;
	}
    }

    return $info;
}

sub write_etc_pve_subscription {
    my ($filename, $fh, $info) = @_;

    if ($info->{status} eq 'New') {
	PVE::Tools::safe_print($filename, $fh, "$info->{key}\n");
	return;
    }

    my $json = encode_json($info);
    my $data = encode_base64($json);
    my $csum = md5_base64($info->{checktime} . $data . $shared_key_data);
    
    my $raw = "$info->{key}\n$csum\n$data";

    PVE::Tools::safe_print($filename, $fh, $raw);
}

sub check_subscription {
    my ($key) = @_;

    my $whmcsurl = "http://shop2.maurer-it.com";

    my $uri = "$whmcsurl/modules/servers/licensing/verify.php";
 
    my $server_id = get_hwaddress();

    my $req_sockets = get_sockets();

    my $check_token = time() . md5_hex(rand(8999999999) + 1000000000) . $key;

    my $params = {
	licensekey => $key,
	domain => $server_id,
	ip => 'localhost',
	check_token => $check_token,
    };

    my $req = HTTP::Request->new('POST' => $uri);
    $req->header('Content-Type' => 'application/x-www-form-urlencoded'); 
    # We use a temporary URI object to format
    # the application/x-www-form-urlencoded content.
    my $url = URI->new('http:');
    $url->query_form(%$params);
    my $content = $url->query;
    $req->header('Content-Length' => length($content));
    $req->content($content);

    my $ua = LWP::UserAgent->new(protocols_allowed => [ 'http', 'https' ], timeout => 30);
    my $response = $ua->request($req);
    my $code = $response->code;

    if ($code != 200) {
	my $msg = $response->message || 'unknown';
	die "Invalid response from server: $code $msg\n";
    }

    my $raw = $response->decoded_content;

    my $subinfo = {};
    while ($raw =~ m/<(.*?)>([^<]+)<\/\1>/g) {
	my ($k, $v) = ($1, $2);
	$subinfo->{$k} = $v;
    }
    $subinfo->{checktime} = time();
    $subinfo->{key} = $key;

    my $emd5sum = md5_hex($shared_key_data . $check_token);
    if (!$subinfo->{md5hash} || ($subinfo->{md5hash} ne $emd5sum)) {
	die "MD5 Checksum Verification Failed";
    }
    
    check_fields($subinfo, $server_id, $req_sockets);
 
    return $subinfo;
}

__PACKAGE__->register_method ({
    name => 'get', 
    path => '', 
    method => 'GET',
    description => "Read subscription info.",
    proxyto => 'node',
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	},
    },
    returns => { type => 'object'},
    code => sub {
	my ($param) = @_;

	my $info = PVE::INotify::read_file('subscription');
	if (!$info) {
	    return {
		status => "NotFound",
		message => "There is no subscription key",
	    }
	}
	return $info
    }});

__PACKAGE__->register_method ({
    name => 'update', 
    path => '', 
    method => 'POST',
    description => "Update subscription info.",
    proxyto => 'node',
    protected => 1,
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    force => {
		description => "Always connect to server, even if we have up to date info inside local cache.",
		type => 'boolean',
		optional => 1,
		default => 0
	    }
	},
    },
    returns => { type => 'null'},
    code => sub {
	my ($param) = @_;

	my $info = PVE::INotify::read_file('subscription');
	return undef if !$info;

	if (!$param->{force} && $info->{status} eq 'Active') {
	    my $age = time() -  $info->{checktime};
	    return undef if $age < $localkeydays*60*60*24;
	}
	
	my $key = $info->{key};

	$info = check_subscription($key);

	PVE::INotify::write_file('subscription', $info);

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'set', 
    path => '', 
    method => 'PUT',
    description => "Set subscription key.",
    proxyto => 'node',
    protected => 1,
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    key => {
		description => "Proxmox VE subscription key",
		type => 'string',
	    },
	},
    },
    returns => { type => 'null'},
    code => sub {
	my ($param) = @_;

	my $info = {
	    status => 'New',
	    key => $param->{key},
	    checktime => time(),
	};

	my $req_sockets = get_sockets();
	my $server_id = get_hwaddress();

	check_fields($info, $server_id, $req_sockets);

	PVE::INotify::write_file('subscription', $info);

	$info = check_subscription($param->{key});

	PVE::INotify::write_file('subscription', $info);

	return undef;
    }});

1;