package RoboDuck;
# ABSTRACT: The IRC bot of the #duckduckgo Channel

sub POE::Kernel::USE_SIGCHLD () { 1 }

use Moses;
use namespace::autoclean;
use Cwd;

our $VERSION ||= '0.0development';

use WWW::DuckDuckGo;
use POE::Component::IRC::Plugin::Karma;
use Cwd qw( getcwd );
use File::Spec;
use Try::Tiny;
use HTML::Entities;
use JSON::XS;
use POE::Component::IRC::Plugin::SigFail;
use POE::Component::WWW::Shorten;
use POE::Component::FastCGI;

with qw(
	MooseX::Daemonize
);

if ($ENV{ROBODUCK_XMPP_JID} and $ENV{ROBODUCK_XMPP_PASSWORD}) {
	with 'RoboDuck::XMPP';
}

server $ENV{USER} eq 'roboduck' ? 'irc.freenode.net' : 'irc.perl.org';
nickname defined $ENV{ROBODUCK_NICKNAME} ? $ENV{ROBODUCK_NICKNAME} : $ENV{USER} eq 'roboduck' ? 'RoboDuck' : 'RoboDuckDev';
channels '#duckduckgo';
username 'duckduckgo';
plugins (
	'Karma' => POE::Component::IRC::Plugin::Karma->new(
		extrastats => 1,
		sqlite => File::Spec->catfile( getcwd(), 'karma_stats.db' ),),
		'SigFail' => POE::Component::IRC::Plugin::SigFail->new
);

after start => sub {
	my $self = shift;
	return unless $self->is_daemon;

	$self->fcgi; # init it!

	# Required, elsewhere your POE goes nuts
	POE::Kernel->has_forked if !$self->foreground;
	POE::Kernel->run;
};

has fcgi => (
	is => 'ro',
	isa => 'Int',
	traits => [ 'NoGetopt' ],
	lazy_build => 1
);

sub _build_fcgi {
	my $self = shift;
	POE::Component::FastCGI->new(
		Port => 6011,
		Handlers => [
			[ '/roboduck/msg' => sub {
					my $request = shift;
					$self->external_message( $request->query('text') );

					my $response = $request->make_response;
					$response->header( "Content-Type" => "text/plain" );
					$response->content( "OK!" );
					# $response->send; # can't do this because it breaks POCO::FastCGI
				} ],

			[ '/roboduck/gh-commit' => sub {
					my $request = shift;
					print $request->query('payload');
					$self->received_git_commit( decode_json($request->query('payload')) );

					my $response = $request->make_response;
					$response->header( "Content-Type" => "text/plain" );
					$response->content( "OK!" );
				} ],
		]
	);
}

has shorten => (
	is => 'ro',
	isa => 'POE::Component::WWW::Shorten',
	traits => [ 'NoGetopt' ],
	lazy_build => 1
);

sub _build_shorten {
	my $self = shift;

	my $type;
	my @params;
	if ( defined $ENV{ROBODUCK_BITLY_USERNAME} && defined $ENV{ROBODUCK_BITLY_KEY} ) {
		$type = 'Bitly';
		@params = ($ENV{ROBODUCK_BITLY_USERNAME}, $ENV{ROBODUCK_BITLY_KEY});
	} else {
		$type = 'IsGd';
	}

	POE::Component::WWW::Shorten->spawn(
		alias => 'shorten',
		type => $type,
		params => \@params
	);
}

has ddg => (
	isa => 'WWW::DuckDuckGo',
	is => 'rw',
	traits => [ 'NoGetopt' ],
	lazy => 1,
	default => sub { WWW::DuckDuckGo->new( http_agent_name => __PACKAGE__.'/'.$VERSION ) },
);

has '+pidbase' => (
	default => sub { getcwd },
);

sub external_message {
	my ( $self, $msg ) = @_;

	for (@{$self->get_channels}) {
		$self->privmsg( $_ => $msg );
	}
}

sub received_git_commit {
	my ( $self, $info ) = @_;

	my ( $pusher, $repo, $commits, $ref ) = @{$info}{ 'pusher', 'repository', 'commits', 'ref' };
	$ref =~ s{^refs/heads/}{};

	my $repo_name = $repo->{name};
	my $pusher_name = $pusher->{name};
	my $commit_count = scalar @{$commits};
	my $plural = ($commit_count == 1) ? '' : 's';

	my $initial_msg = "[git] $pusher_name pushed $commit_count commit$plural to $repo_name/$ref";

	for (@{$self->get_channels}) {
		$self->privmsg( $_ => $initial_msg );
	}

	for (@{$commits}) {
		my ( $id, $url, $author, $msg ) = @{$_}{ 'id', 'url', 'author', 'message' };
		my $short_id = substr $id, 0, 7;
		my $author_name = $author->{name};

		my $commit_message = "[$short_id] $author_name - $msg SHORT_URL";
		$self->shorten->shorten({
				url => $url,
				event => 'announce_shortened_url',
				session => $self->get_session_id,
				_message => $commit_message
			});
	}
}

event announce_shortened_url => sub {
	my ( $self, $returned ) = @_[ OBJECT, ARG0 ];

	my ( $message, $url ) = @{$returned}{ '_message', 'short' };
	$message =~ s/SHORT_URL/$url/;

	for (@{$self->get_channels}) {
		$self->privmsg( $_ => $message );
	}
};

event irc_public => sub {
	my ( $self, $nickstr, $channels, $msg ) = @_[ OBJECT, ARG0, ARG1, ARG2 ];
	my $what = lc($msg);
	my $nick = lc($self->nick);
	if ( $what =~ /^$nick(\?|!|:)(|\s|$)/) {
		$what =~ s/^$nick\??:?!?(\s|$)?//i;
		&myself($self,$nickstr,$channels->[0],$what);
	}
	if ( $what =~ /^(!|\?)\s/ ) {
		$what =~ s/^(!|\?)\s//;
		&myself($self,$nickstr,$channels->[0],$what);
	}
	if ($msg =~ /^!yesorno /i) {
		my $zci = $self->ddg->zci("yes or no");
		for (@{$channels}) {
			$self->privmsg( $_ => "The almighty DuckOracle says..." );
		}
		if ($zci->answer =~ /^no /) {
			for (@{$channels}) {
				$self->delay_add( say_later => 2, $_, "... no" );
			}
		} else {
			for (@{$channels}) {
				$self->delay_add( say_later => 2, $_, "... yes" );
			}
		}
		return;
	}
};

event irc_msg => sub {
	my ( $self, $nickstr, $msg ) = @_[ OBJECT, ARG0, ARG2 ];
	my $what = lc($msg);
	my $mynick = lc($self->nick);
	my ( $nick ) = split /!/, $nickstr;
	&myself($self,$nickstr,$nick,$what);
};
	

sub myself {
	my ( $self, $nickstr, $channel, $msg ) = @_;
	my ( $nick ) = split /!/, $nickstr;
	$self->debug($nick.' told me "'.$msg.'" on '.$channel);
	my $reply;
	my $zci;
	try {
		if (!$msg) {
			$reply = "I'm here in version ".$VERSION ;
		} elsif ($msg =~ /your order/i or $msg =~ /your rules/i) {
			$reply = "1. Serve the public trust, 2. Protect the innocent, 3. Uphold the law, 4. .... and dont track you! http://donttrack.us/";
		} elsif ($zci = $self->ddg->zci($msg)) {
			if ($zci->has_answer) {
				$reply = $zci->answer;
				$reply .= " (".$zci->answer_type.")";
			} elsif ($zci->has_definition) {
				$reply = $zci->definition;
				$reply .= " (".$zci->definition_source.")" if $zci->has_definition_source;
			} elsif ($zci->has_abstract_text) {
				$reply = $zci->abstract_text;
				$reply .= " (".$zci->abstract_source.")" if $zci->has_abstract_source;
			} elsif ($zci->has_heading) {
				$reply = $zci->heading;
			} else {
				$reply = '<irc_sigfail:FAIL>';
			}
			$reply .= " ".$zci->definition_url if $zci->has_definition_url;
			$reply .= " ".$zci->abstract_url if $zci->has_abstract_url;
		} else {
			$reply = '0 :(';
		}
		$reply = decode_entities($reply);
		$self->privmsg( $channel => "$nick: ".$reply );
	} catch {
		$self->privmsg( $channel => "doh!" );
	}
};

event say_later => sub {
	my ( $self, $channel, $msg ) = @_[ OBJECT, ARG0, ARG1 ];
	$self->privmsg( $channel => $msg );
};

event 'no' => sub {
};

1;
