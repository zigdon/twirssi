use strict;
use Irssi;
use Irssi::Irc;
use HTTP::Date;
use HTML::Entities;
use File::Temp;
use LWP::Simple;
use Data::Dumper;
use Encode;
use FileHandle;
use POSIX qw/:sys_wait_h strftime/;
use Net::Twitter qw/3.11009/;
use JSON::Any;
use DateTime;
use DateTime::Format::Strptime;
$Data::Dumper::Indent = 1;

use vars qw($VERSION %IRSSI);

$VERSION = sprintf '%s', q$Version: v2.6.0$ =~ /^\w+:\s+v(\S+)/;
%IRSSI   = (
    authors     => '@zigdon, @gedge',
    contact     => 'zigdon@gmail.com',
    name        => 'twirssi',
    description => 'Send twitter updates using /tweet.  '
      . 'Can optionally set your bitlbee /away message to same',
    license => 'GNU GPL v2',
    url     => 'http://twirssi.com',
    changed => '$Date: 2013-06-08 13:30:00 +0000$',
);

my $twit;	# $twit is current logged-in Net::Twitter object (usually one of %twits)
my %twits;	# $twits{$username} = logged-in object
my %oauth;
my $user;	# current $account
my $defservice; # current $service
my $poll_event;		# timeout_add event object (regular update)
my %last_poll;		# $last_poll{$username}{tweets|friends|blocks|lists}	= time of last update
			#	    {__interval|__poll}			= time
my %nicks;              # $nicks{$screen_name} = last seen/mentioned time (for sorting completions)
my %friends;		# $friends{$username}{$nick} = $epoch_when_refreshed (rhs value used??)
my %blocks;		# $blocks {$username}{$nick} = $epoch_when_refreshed (rhs value used??)
my %tweet_cache;	# $tweet_cache{$tweet_id} = time of tweet (helps keep last hour of IDs, to avoid dups)
my %state;
		# $state{__ids}			{$lc_nick}[$cache_idx]	= $tweet_id
		# $state{__tweets}		{$lc_nick}[$cache_idx]	= $tweet_text
		# $state{__usernames}		{$lc_nick}[$cache_idx]	= $username_that_polled_tweet
		# $state{__reply_to_ids}	{$lc_nick}[$cache_idx]	= $polled_tweet_replies_to_this_id
		# $state{__reply_to_users}	{$lc_nick}[$cache_idx]	= $polled_tweet_replies_to_this_user
		# $state{__created_ats}		{$lc_nick}[$cache_idx]	= $time_of_tweet
		# $state{__indexes}		{$lc_nick}		= $last_cache_idx_used
		# $state{__last_id}	{$username}{timeline|reply|dm}	= $id_of_last_tweet
		#				   {__sent}		= $id_of_last_tweet_from_act
		#				   {__extras}{$lc_nick}	= $id_of_last_tweet (fix_replies)
		#				   {__search}{$topic}	= $id_of_last_tweet
		# $state{__lists}	{$username}{$list_name}		= { id => $list_id, members=>[$nick,...] }
		# $state{__channels}	{$type}{$tag}{$net_tag}		= [ channel,... ]
		# $state{__windows}	{$type}{$tag}			=  $window_name
my $failstatus = 0;		# last update status:  0=ok, 1=warned, 2=failwhaled
my $first_call = 1;
my $child_pid;
my %fix_replies_index;	# $fix_replies_index($username} = 0..100 idx in sort keys $state{__last_id}{$username}{__extras}
my %search_once;
my $update_is_running = 0;
my %logfile;
my %settings;
my %last_ymd;		# $last_ymd{$chan_or_win} = $last_shown_ymd
my @datetime_parser;
my %completion_types = ();
my %expanded_url = ();
my $ua;
my %valid_types = (
	'window'	=> [ qw/ tweet search dm reply sender error default /],	# twirssi_set_window
	'channel'	=> [ qw/ tweet search dm reply sender error * / ],	# twirssi_set_channel
);

my $local_tz = DateTime::TimeZone->new( name => 'local' );

my @settings_defn = (
        [ 'broadcast_users',   'twirssi_broadcast_users',   's', undef,			'list{,}' ],
        [ 'charset',           'twirssi_charset',           's', 'utf8', ],
        [ 'default_service',   'twirssi_default_service',   's', 'Twitter', ],
        [ 'ignored_accounts',  'twirssi_ignored_accounts',  's', '',			'list{,},norm_user' ],
        [ 'ignored_twits',     'twirssi_ignored_twits',     's', '',			'lc,list{,}' ],
        [ 'ignored_tags',      'twirssi_ignored_tags',      's', '',			'lc,list{,}' ],
        [ 'location',          'twirssi_location',          's', Irssi::get_irssi_dir . "/scripts/$IRSSI{name}.pl" ],
        [ 'nick_color',        'twirssi_nick_color',        's', '%B', ],
        [ 'ymd_color',         'twirssi_ymd_color',         's', '%r', ],
        [ 'oauth_store',       'twirssi_oauth_store',       's', Irssi::get_irssi_dir . "/scripts/$IRSSI{name}.oauth" ],
        [ 'replies_store',     'twirssi_replies_store',     's', Irssi::get_irssi_dir . "/scripts/$IRSSI{name}.json" ],
        [ 'dump_store',        'twirssi_dump_store',        's', Irssi::get_irssi_dir . "/scripts/$IRSSI{name}.dump" ],
        [ 'poll_store',        'twirssi_poll_store',        's', Irssi::get_irssi_dir . "/scripts/$IRSSI{name}.polls" ],
        [ 'id_store',          'twirssi_id_store',          's', Irssi::get_irssi_dir . "/scripts/$IRSSI{name}.ids" ],
        [ 'retweet_format',    'twirssi_retweet_format',    's', 'RT $n: "$t" ${-- $c$}' ],
        [ 'retweeted_format',  'twirssi_retweeted_format',  's', 'RT $n: $t' ],
        [ 'stripped_tags',     'twirssi_stripped_tags',     's', '',			'list{,}' ],
        [ 'topic_color',       'twirssi_topic_color',       's', '%r', ],
        [ 'timestamp_format',  'twirssi_timestamp_format',  's', '%H:%M:%S', ],
        [ 'window_priority',   'twirssi_window_priority',   's', 'account', ],
        [ 'upgrade_branch',    'twirssi_upgrade_branch',    's', 'master', ],
        [ 'upgrade_dev',       'twirssi_upgrade_dev',       's', 'zigdon', ],
        [ 'bitlbee_server',    'bitlbee_server',            's', 'bitlbee' ],
        [ 'hilight_color',     'twirssi_hilight_color',     's', '%M' ],
        [ 'unshorten_color',   'twirssi_unshorten_color',   's', '%b' ],
        [ 'passwords',         'twitter_passwords',         's', undef,			'list{,}' ],
        [ 'usernames',         'twitter_usernames',         's', undef,			'list{,}' ],
        [ 'update_usernames',  'twitter_update_usernames',  's', undef,			'list{,}' ],
        [ 'url_provider',      'short_url_provider',        's', 'TinyURL' ],
        [ 'url_unshorten',     'short_url_domains',         's', '',			'lc,list{ }' ],
        [ 'url_args',          'short_url_args',            's', undef ],
        [ 'window',            'twitter_window',            's', 'twitter' ],
        [ 'debug_win_name',    'twirssi_debug_win_name',    's', '' ],
        [ 'limit_user_tweets', 'twitter_user_results',      's', '20' ],

        [ 'always_shorten',    'twirssi_always_shorten',    'b', 0 ],
        [ 'rt_to_expand',      'twirssi_retweet_to_expand', 'b', 1 ],
        [ 'avoid_ssl',         'twirssi_avoid_ssl',         'b', 0 ],
        [ 'debug',             'twirssi_debug',             'b', 0 ],
        [ 'notify_timeouts',   'twirssi_notify_timeouts',   'b', 1 ],
        [ 'logging',           'twirssi_logging',           'b', 0 ],
        [ 'mini_whale',        'twirssi_mini_whale',        'b', 0 ],
        [ 'own_tweets',        'show_own_tweets',           'b', 1 ],
        [ 'to_away',           'tweet_to_away',             'b', 0 ],
        [ 'upgrade_beta',      'twirssi_upgrade_beta',      'b', 1 ],
        [ 'use_oauth',         'twirssi_use_oauth',         'b', 1 ],
        [ 'use_reply_aliases', 'twirssi_use_reply_aliases', 'b', 0 ],
        [ 'window_input',      'tweet_window_input',        'b', 0 ],
        [ 'retweet_classic',   'retweet_classic',           'b', 0 ],
        [ 'retweet_show',      'retweet_show',              'b', 0 ],
        [ 'force_first',       'twirssi_force_first',       'b', 0 ],

        [ 'friends_poll',      'twitter_friends_poll',      'i', 600 ],
        [ 'blocks_poll',       'twitter_blocks_poll',       'i', 900 ],
        [ 'lists_poll',        'twitter_lists_poll',        'i', 900 ],
        [ 'poll_interval',     'twitter_poll_interval',     'i', 300 ],
        [ 'poll_schedule',     'twitter_poll_schedule',     's', '',			'list{,}' ],
        [ 'search_results',    'twitter_search_results',    'i', 5 ],
        [ 'autosearch_results','twitter_autosearch_results','i', 0 ],
        [ 'timeout',           'twitter_timeout',           'i', 30 ],
        [ 'track_replies',     'twirssi_track_replies',     'i', 100 ],
);

my %meta_to_twit = (    # map file keys to twitter keys
        'id'		=> 'id',
        'created_at'    => 'created_at',
        'reply_to_user'	=> 'in_reply_to_screen_name',
        'reply_to_id'	=> 'in_reply_to_status_id',
);

my %irssi_to_mirc_colors = (
    '%k' => '01',
    '%r' => '05',
    '%g' => '03',
    '%y' => '07',
    '%b' => '02',
    '%m' => '06',
    '%c' => '10',
    '%w' => '15',
    '%K' => '14',
    '%R' => '04',
    '%G' => '09',
    '%Y' => '08',
    '%B' => '12',
    '%M' => '13',
    '%C' => '11',
    '%W' => '00',
);

sub cmd_direct {
    my ( $data, $server, $win ) = @_;

    my ( $target, $text ) = split ' ', $data, 2;
    unless ( $target and $text ) {
        &notice( ["dm"], "Usage: /dm <nick> <message>" );
        return;
    }

    &cmd_direct_as( "$user $data", $server, $win );
}

sub cmd_direct_as {
    my ( $data, $server, $win ) = @_;

    my ( $username, $target, $text ) = split ' ', $data, 3;
    unless ( $username and $target and $text ) {
        &notice( ["dm"], "Usage: /dm_as <username> <nick> <message>" );
        return;
    }

    return unless $username = &valid_username($username);
    return unless &logged_in($twits{$username});

    my $target_norm = &normalize_username($target, 1);

    $text = &shorten($text);

    return if &too_long($text, ['dm', $target_norm]);

    eval {
        if ( $twits{$username}
            ->new_direct_message( { screen_name => $target, text => $text } ) ) {
            &notice( [ "dm", $target_norm ], "DM sent to $target: $text" );
            $nicks{$target} = time;
        } else {
            my $error;
            eval {
                $error = JSON::Any->jsonToObj( $twits{$username}->get_error() );
                $error = $error->{error};
            };
            die "$error\n" if $error;
            &notice( [ "dm", $target_norm ], "DM to $target failed" );
        }
    };

    if ($@) {
        &notice( ["error"], "DM caused an error: $@" );
        return;
    }
}

sub cmd_retweet {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//;
    unless ($data) {
        &notice( [ "tweet", $user ], "Usage: /retweet <nick[:num]> [comment]" );
        return;
    }

    (my $id, $data ) = split ' ', $data, 2;

    &cmd_retweet_as( "$user $id $data", $server, $win );
}

sub cmd_retweet_as {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//;
    ( my $username, my $id, $data ) = split ' ', $data, 3;

    unless ($username) {
        &notice( ["tweet"],
            "Usage: /retweet_as <username> <nick[:num]> [comment]" );
        return;
    }

    return unless $username = &valid_username($username);

    return unless &logged_in($twits{$username});

    my $nick;
    $id =~ s/[^\w\d\-:]+//g;
    ( $nick, $id ) = split /:/, $id;
    unless ( exists $state{__ids}{ lc $nick } ) {
        &notice( [ "tweet", $username ],
            "Can't find a tweet from $nick to retweet!" );
        return;
    }

    $id = $state{__indexes}{lc $nick} unless defined $id;
    unless ( $state{__ids}{ lc $nick }[$id] ) {
        &notice( [ "tweet", $username ],
            "Can't find a tweet numbered $id from $nick to retweet!" );
        return;
    }

    unless ( $state{__tweets}{ lc $nick }[$id] ) {
        &notice( [ "tweet", $username ],
            "The text of this tweet isn't saved, sorry!" );
        return;
    }

    my $text = &format_expand(fmt => $settings{retweet_format}, nick => $nick, data => $data,
                 tweet => $state{__tweets}{ lc $nick }[$id]);

    my $modified = $data;
    $data = &shorten($text);

    return if ($modified or $settings{retweet_classic})
              and &too_long($data, ['tweet', $username]);

    my $success = 1;
    my $extra_info = '';
    eval {
        if ($modified or $settings{retweet_classic}) {
            $success = $twits{$username}->update(
                {
                    status => $data,
                    # in_reply_to_status_id => $state{__ids}{ lc $nick }[$id]
                }
            );
            $extra_info = ' (classic/edited)';
        } else {
            $success =
              $twits{$username}->retweet( { id => $state{__ids}{ lc $nick }[$id] } );
            # $retweeted_id{$username}{ $state{__ids}{ lc $nick }[$id] } = 1;
            $extra_info = ' (native)';
        }
    };
    unless ($success) {
        &notice( [ "tweet", $username ], "Update failed" );
        return;
    }

    if ($@) {
        &notice( [ "error", $username ],
            "Update caused an error: $@.  Aborted" );
        return;
    }

    $extra_info .= ' id=' . $success->{id} if $settings{debug};

    foreach ( $data =~ /@([-\w]+)/g ) {
        $nicks{$_} = time;
    }

    &notice( [ "tweet", $username ], "Retweet of $nick:$id sent" . $extra_info );
}


sub format_expand {
    my %args = @_;
    $args{fmt} =~ s/\$n/\@$args{nick}/g;
    if (defined $args{data} and $args{data} ne '') {
        $args{fmt} =~ s/\${|\$}//g;
        $args{fmt} =~ s/\$c/$args{data}/g;
    } else {
        $args{fmt} =~ s/\${.*?\$}//g;
    }
    $args{fmt} =~ s/\$t/$args{tweet}/g;
    return $args{fmt};
}


sub cmd_retweet_to_window {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//;

    ( my $id, $data ) = split ' ', $data, 2;
    $id =~ s/[^\w\d\-:]+//g;
    ( my $nick, $id ) = split ':', $id;
    unless ( exists $state{__ids}{ lc $nick } ) {
        &notice( [ "tweet" ],
            "Can't find a tweet from $nick to retweet!" );
        return;
    }

    $id = $state{__indexes}{lc $nick} unless defined $id;
    unless ( $state{__ids}{ lc $nick }[$id] ) {
        &notice( [ "tweet" ],
            "Can't find a tweet numbered $id from $nick to retweet!" );
        return;
    }

    unless ( $state{__tweets}{ lc $nick }[$id] ) {
        &notice( [ "tweet" ],
            "The text of this tweet isn't saved, sorry!" );
        return;
    }

    my $target = '';
    my $got_net = 0;
    my $got_target = 0;
    while (not $got_target and $data =~ s/^(\S+)\s*//) {
        my $arg = $1;
        if (not $got_net and lc($arg) ne '-channel' and lc($arg) ne '-nick' and $arg =~ /^-/) {
            $got_net = 1;
        } else {
            if (lc($arg) eq '-channel' or lc($arg) eq '-nick') {
                last if not $data =~ s/^(\S+)\s*//;
                $arg .= " $1";
            }
            $got_target = 1;
        }
        $target .= ($target ne '' ? ' ' : '') . $arg;
    }
    if (not $got_target) {
        &notice( [ "tweet" ], "Missing target." );
        return;
    }

    my $text = &format_expand(fmt => $settings{retweet_format}, nick => $nick, data => $data,
                 tweet => &post_process_tweet($state{__tweets}{ lc $nick }[$id], not $settings{rt_to_expand}));

    Irssi::command("msg $target $text");

    foreach ( $text =~ /@([-\w]+)/g ) {
        $nicks{$_} = time;
    }

    &debug("Retweet of $nick:$id sent to $target");
}

sub cmd_reload {
    if ($settings{force_first} and $settings{poll_store}) {
        &save_state();
        &save_polls();
    }
    Irssi::command("script load $IRSSI{name}");
}

sub cmd_tweet {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//;
    unless ($data) {
        &notice( ["tweet"], "Usage: /tweet <update>" );
        return;
    }

    &cmd_tweet_as( "$user\@$defservice $data", $server, $win );
}

sub cmd_tweet_as {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//;
    $data =~ s/\s\s+/ /g;
    ( my $username, $data ) = split ' ', $data, 2;

    unless ( $username and $data ) {
        &notice( ["tweet"], "Usage: /tweet_as <username> <update>" );
        return;
    }

    return unless $username = &valid_username($username);

    return unless &logged_in($twits{$username});

    $data = &shorten($data);

    return if &too_long($data, ['tweet', $username]);

    my $success = 1;
    my $res;
    eval {
        unless ( $res = $twits{$username}->update($data) ) {
            &notice( [ "tweet", $username ], "Update failed" );
            $success = 0;
        }
    };
    return unless $success;

    if ($@) {
        &notice( [ "error", $username ],
            "Update caused an error: $@.  Aborted." );
        return;
    }

    foreach ( $data =~ /@([-\w]+)/g ) {
        $nicks{$_} = time;
    }

    # TODO: What's the official definition of a Hashtag? Let's use #[-\w]+ like above for now.
    if ( $settings{autosearch_results} > 0 and $data =~ /#[-\w]+/ ) {
	my @topics;
	while ( $data =~ /(#[-\w]+)/g ) {
	    push @topics, $1;
	    $search_once{$username}->{$1} = $settings{autosearch_results};
	}
	&get_updates([ 0, [
			   [ $username, { up_searches => [ @topics ] } ],
		       ],
		     ]);
    }

    $state{__last_id}{$username}{__sent} = $res->{id};
    my $id_info = ' id=' . $res->{id} if $settings{debug};

    my $away_info = '';
    if ( $username eq "$user\@$defservice"
          and $settings{to_away}
          and &update_away($data) ) {
        $away_info = " (and away msg set)";
    }
    &notice( [ "tweet", $username ], "Update sent" . $away_info . $id_info );
}

sub cmd_broadcast {
    my ( $data, $server, $win ) = @_;

    my @bcast_users = @{ $settings{broadcast_users} };
    @bcast_users = keys %twits if not @bcast_users;

    foreach my $buser (@bcast_users) {
        &cmd_tweet_as( "$buser $data", $server, $win );
    }
}

sub cmd_info {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//g;
    unless ( $data ) {
        &notice( ["info"], "Usage: /twitter_info <nick[:num]>" );
        return;
    }

    $data =~ s/[^\w\-:]+//g;
    my ( $nick_orig, $id ) = split /:/, $data;
    my $nick = lc $nick_orig;
    unless ( exists $state{__ids}{ $nick } ) {
        &notice( [ "info" ],
            "Can't find any tweet from $nick_orig!" );
        return;
    }

    $id = $state{__indexes}{$nick} unless defined $id;
    my $statusid = $state{__ids}{$nick}[$id];
    unless ( $statusid ) {
        &notice( [ "info" ],
            "Can't find a tweet numbered $id from $nick_orig!" );
        return;
    }

    my $username      = $state{__usernames}{$nick}[$id];
    my $timestamp     = $state{__created_ats}{$nick}[$id];
    my $tweet         = $state{__tweets}{$nick}[$id];
    my $reply_to_id   = $state{__reply_to_ids}{$nick}[$id];
    my $reply_to_user = $state{__reply_to_users}{$nick}[$id];
    my $exp_tweet     = $tweet;
    if ($tweet) {
        $tweet        = &post_process_tweet($tweet, 1);
        $exp_tweet    = &post_process_tweet($exp_tweet);
    }

    my $url = '';
    if ( defined $username ) {
        if ( $username =~ /\@Twitter/ ) {
            $url = "http://twitter.com/$nick/statuses/$statusid";
        } elsif ( $username =~ /\@Identica/ ) {
            $url = "http://identi.ca/notice/$statusid";
        }
    }

    &notice( [ "info" ], ",--------- $nick:$id" );
    &notice( [ "info" ], "| nick:    $nick_orig <http://twitter.com/$nick_orig>" );
    &notice( [ "info" ], "| id:      $statusid" . ($url ? " <$url>" : ''));
    &notice( [ "info" ], "| time:    " . ($timestamp
                             ? DateTime->from_epoch( epoch => $timestamp, time_zone => $local_tz)
                             : '<unknown>') );
    &notice( [ "info" ], "| account: " . ($username ? $username : '<unknown>' ) );
    &notice( [ "info" ], "| text:    " . ($tweet ? $tweet : '<unknown>' ) );
    &notice( [ "info" ], "|    +url: " . $exp_tweet ) if $exp_tweet ne $tweet;

    if ($reply_to_id and $reply_to_user) {
       &notice( [ "info" ], "| ReplyTo: $reply_to_user:$reply_to_id" );
       &notice( [ "info" ], "| thread:  http://twitter.theinfo.org/$statusid");
    }
    &notice( [ "info" ], "`---------" );
}

sub cmd_reply {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//;
    unless ($data) {
        &notice( ["reply"], "Usage: /reply <nick[:num]> <update>" );
        return;
    }

    ( my $id, $data ) = split ' ', $data, 2;
    unless ( $id and $data ) {
        &notice( ["reply"], "Usage: /reply <nick[:num]> <update>" );
        return;
    }

    &cmd_reply_as( "$user $id $data", $server, $win );
}

sub cmd_reply_as {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//;
    ( my $username, my $id, $data ) = split ' ', $data, 3;

    unless ( $username and $data ) {
        &notice( ["reply"],
            "Usage: /reply_as <username> <nick[:num]> <update>" );
        return;
    }

    return unless $username = &valid_username($username);

    return unless &logged_in($twits{$username});

    my $nick;
    $id =~ s/[^\w\d\-:]+//g;
    ( $nick, $id ) = split /:/, $id;
    unless ( exists $state{__ids}{ lc $nick } ) {
        &notice( [ "reply", $username ],
            "Can't find a tweet from $nick to reply to!" );
        return;
    }

    $id = $state{__indexes}{lc $nick} unless defined $id;
    unless ( $state{__ids}{ lc $nick }[$id] ) {
        &notice( [ "reply", $username ],
            "Can't find a tweet numbered $id from $nick to reply to!" );
        return;
    }

    $data = "\@$nick $data";
    $data = &shorten($data);

    return if &too_long($data, ['reply', $username]);

    my $success = 1;
    eval {
        unless (
            $twits{$username}->update(
                {
                    status                => $data,
                    in_reply_to_status_id => $state{__ids}{ lc $nick }[$id]
                }
            )
          ) {
            &notice( [ "reply", $username ], "Update failed" );
            $success = 0;
        }
    };
    return unless $success;

    if ($@) {
        &notice( [ "reply", $username ],
            "Update caused an error: $@.  Aborted" );
        return;
    }

    foreach ( $data =~ /@([-\w]+)/g ) {
        $nicks{$_} = time;
    }

    my $away = $settings{to_away} ? &update_away($data) : 0;

    &notice( [ "reply", $username ],
        "Update sent" . ( $away ? " (and away msg set)" : "" ) );
}

sub gen_cmd {
    my ( $usage_str, $api_name, $post_ref, $data_ref ) = @_;

    return sub {
        my ( $data, $server, $win ) = @_;

        return unless &logged_in($twit);

        if ($data_ref) {
            $data = $data_ref->($data);
        }

        $data =~ s/^\s+|\s+$//;
        unless ($data) {
            &notice("Usage: $usage_str");
            return;
        }

        my $success = 1;
        eval {
            unless ( $twit->$api_name($data) ) {
                &notice("$api_name failed");
                $success = 0;
            }
        };
        return unless $success;

        if ($@) {
            &notice(['error'], "$api_name caused an error.  Aborted: $@");
            return;
        }

        &$post_ref($data, $server, $win) if $post_ref;
      }
}

sub cmd_listinfo {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//g;
    if ( length $data > 0 ) {
        my ($list_user, $list_name) = split(' ', lc $data, 2);
        my $list_account = &normalize_username($list_user, 1);
        my $list_ac = ($list_account eq "$user\@$defservice" ? '' : "$list_account/");
        if (defined $list_name) {
            &notice("Getting list: '$list_ac$list_name'");
        } else {
            &notice("Getting all lists for '$list_account'");
        }
        &get_updates([ 0, [
                                [ "$user\@$defservice", { up_lists => [ $list_user, $list_name ] } ],
                        ],
        ]);

    } else {
        &notice( ['error'], 'Usage: /twitter_listinfo [ <user> [<list name>] ]' );
    }
}

sub cmd_search {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//g;
    if ( length $data > 0 ) {
        my $username = &normalize_username($user);
        if ( exists $search_once{$username}->{$data} ) {
            &notice( [ "search", $data ], "Search is already queued" );
            return;
        }
        $search_once{$username}->{$data} = $settings{search_results};
        &notice( [ "search", $data ], "Searching for '$data'" );
        &get_updates([ 0, [
                                [ $username, { up_searches => [ $data ] } ],
                        ],
        ]);
    } else {
        &notice( ["search"], "Usage: /twitter_search <search term>" );
    }
}


sub cmd_dms_as {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//g;
    ( my $username, $data ) = split ' ', $data, 2;
    unless ( $username ) {
        &notice( ['dm'], 'Usage: /twitter_dms_as <username>' );
        return;
    }
    return unless $username = &valid_username($username);
    return unless &logged_in($twits{$username});

    if ( length $data > 0 ) {
        &notice( ['error'], 'Usage: /' .
                      ($username eq "$user\@$defservice"
                          ? 'twitter_dms' : 'twitter_dms_as <username>') );
        return;
    }
    &notice( [ 'dm' ], 'Fetching direct messages' );
    &get_updates([ 0, [
                          [ $username, { up_dms => 1 } ],
                      ],
    ]);
}


sub cmd_dms {
    my ( $data, $server, $win ) = @_;
    &cmd_dms_as("$user $data", $server, $win);
}

sub cmd_switch {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//g;
    $data = &normalize_username($data);
    if ( exists $twits{$data} ) {
        &notice( [ "tweet", $data ], "Switching to $data" );
        $twit = $twits{$data};
        if ( $data =~ /(.*)\@(.*)/ ) {
            $user       = $1;
            $defservice = $2;
        } else {
            &notice( [ "tweet", $data ],
                "Couldn't figure out what service '$data' is on" );
        }
    } else {
        &notice( ["tweet"], "Unknown user $data" );
    }
}

sub cmd_logout {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//g;
    $data = $user unless $data;
    return unless $data = &valid_username($data);

    &notice( [ "tweet", $data ], "Logging out $data..." );
    eval { $twits{$data}->end_session(); };
    delete $twits{$data};
    delete $last_poll{$data};
    undef $twit;
    if ( keys %twits ) {
        &cmd_switch( ( keys %twits )[0], $server, $win );
    } else {
        Irssi::timeout_remove($poll_event) if $poll_event;
        undef $poll_event;
    }
}

sub cmd_login {
    my ( $data, $server, $win ) = @_;
    my $username;
    my $pass;
    &debug("logging in: $data");
    if ($data) {
        ( $username, $pass ) = split ' ', $data, 2;
        unless ( $settings{use_oauth} or $pass ) {
            &notice( ["tweet"],
                "usage: /twitter_login <username>[\@<service>] <password>" );
            return;
        }
        &debug("%G$username%n manual data login");

    } elsif ( $settings{use_oauth} and @{ $settings{usernames} } ) {
        &debug("oauth autouser login @{ $settings{usernames} }" );
        %nicks = ();
        my $some_success = 0;
        foreach my $user ( @{ $settings{usernames} } ) {
            $some_success = &cmd_login($user);
        }
        return $some_success;

    } elsif ( @{ $settings{usernames} } and @{ $settings{passwords} } ) {
        &debug("autouser login");

        if ( @{ $settings{usernames} } != @{ $settings{passwords} } ) {
            &notice( ["error"],
                    "Number of usernames doesn't match "
                  . "the number of passwords - auto-login failed" );
            return;
        } else {
            %nicks = ();
            my $some_success = 0;
            for (my $i = 0;  $i < @{ $settings{usernames} };  $i++) {
                $some_success ||= &cmd_login("$settings{usernames}->[$i] $settings{passwords}->[$i]");
            }
            return $some_success;
        }

    } else {
        &notice( ["error"],
                "/twitter_login requires either a username/password "
              . "or twitter_usernames and twitter_passwords to be set. "
              . "Note that if twirssi_use_oauth is true, passwords are "
              . "not required" );
        return;
    }

    $username = &normalize_username($username, 1);
    ( $user, $defservice ) = split('@', $username, 2);

    $state{__lists}{$username} = {};
    $blocks{$username} = {};
    $friends{$username} = {};

    if ( $defservice eq 'Twitter' and $settings{use_oauth} ) {
        &debug("%G$username%n Attempting OAuth");
        eval {
            if ( $defservice eq 'Identica' ) {
                $twit = Net::Twitter->new(
                    identica => 1,
                    traits   => [ 'API::REST', 'API::Search' ],
                    source   => "twirssi",	# XXX
                    ssl      => !$settings{avoid_ssl},
                );
            } else {
                $twit = Net::Twitter->new(
                    traits =>
                      [ 'API::RESTv1_1', 'OAuth', 'RetryOnError' ],
                    (
                        grep tr/a-zA-Z/n-za-mN-ZA-M/, map $_,
                        pbafhzre_xrl => 'OMINiOzn4TkqvEjKVioaj',
                        pbafhzre_frperg =>
                          '0G5xnujYlo34ipvTMftxN9yfwgTPD05ikIR2NCKZ',
                    ),
                    source => "twirssi",	# XXX
                    ssl    => !$settings{avoid_ssl},
                );
            }
        };

        if ($@) {
            &notice( ["error"], "Error when creating object:  $@" );
        }

        if ($twit) {
            if ( open( my $oa_fh, '<', $settings{oauth_store} ) ) {
                while (<$oa_fh>) {
                    chomp;
                    next unless /^$username (\S+) (\S+)/i;
                    &debug("%G$username%n Trying cached oauth creds");
                    $twit->access_token($1);
                    $twit->access_token_secret($2);
                    last;
                }
                close $oa_fh;
            }

            unless ( $twit->authorized ) {
                my $url;
                eval { $url = $twit->get_authorization_url; };

                if ($@) {
                    &notice( ["error"],
                        "Failed to get OAuth authorization_url: $@" );
                    return;
                }
                &notice( ["error"],
                    "$user: $IRSSI{name} not authorized to access $defservice.",
                    "Please authorize at the following url, then enter the PIN",
                    "supplied with /twirssi_oauth $username <pin>",
                    $url
                );

                $oauth{pending}{$username} = $twit;
                return;
            }
        }
    } else {
        $twit = Net::Twitter->new(
            $defservice eq 'Identica' ? ( identica => 1 ) : (),
            username => $user,
            password => $pass,
            source   => "twirssi",	# XXX
            ssl      => $settings{avoid_ssl},
        );
    }

    unless ($twit) {
        &notice( ["error"], "Failed to create object!  Aborting." );
        return;
    }

    return &verify_twitter_object( $server, $win, $user, $defservice, $twit );
}

sub cmd_oauth {
    my ( $data, $server, $win ) = @_;
    my ( $key, $pin ) = split ' ', $data;
    my ( $user, $service );
    $key = &normalize_username($key);
    if ( $key =~ /^(.*)@(Twitter|Identica)$/ ) {
        ( $user, $service ) = ( $1, $2 );
    }
    $pin =~ s/\D//g;
    &debug("Applying pin to $key");

    unless ( exists $oauth{pending}{$key} ) {
        &notice( ["error"],
                "There isn't a pending oauth request for $key. "
              . "Try /twitter_login first" );
        return;
    }

    my $twit = $oauth{pending}{$key};
    my ( $access_token, $access_token_secret );
    eval {
        ( $access_token, $access_token_secret ) =
          $twit->request_access_token( verifier => $pin );
    };

    if ($@) {
        &notice( ["error"], "Invalid pin, try again: $@" );
        return;
    }

    delete $oauth{pending}{$key};

    my $store_file = $settings{oauth_store};
    if ($store_file) {
        my @store;
        if ( open( my $oa_fh, '<', $store_file ) ) {
            while (<$oa_fh>) {
                chomp;
                next if /$key/i;
                push @store, $_;
            }
            close $oa_fh;

        }

        push @store, "$key $access_token $access_token_secret";

        if ( open( my $oa_fh, '>', "$store_file.new" ) ) {
            print $oa_fh "$_\n" foreach @store;
            close $oa_fh;
            rename "$store_file.new", $store_file
              or &notice( ["error"], "Failed to rename $store_file.new: $!" );
        } else {
            &notice( ["error"], "Failed to write $store_file.new: $!" );
        }
    } else {
        &notice( ["error"],
                "No persistant storage set for OAuth.  "
              . "Please /set twirssi_oauth_store to a writable filename." );
    }

    return &verify_twitter_object( $server, $win, $user, $service, $twit );
}

sub rate_limited {
    my $obj      = shift;
    my $username = shift;
    my $fh       = shift;

    my $rate_limit;
    eval {
        $rate_limit = $obj->rate_limit_status();
    };
    my $res = 0;
    if ( $rate_limit and $rate_limit->{resources} ) {
        for my $resource (keys %{ $rate_limit->{resources} }) {
            for my $uri (keys %{ $rate_limit->{resources}->{$resource} }) {
                if ( $rate_limit->{resources}->{$resource}->{$uri}->{remaining} < 1 ) {
                    &notice( [ 'error', $username, $fh ],
                        "Rate limit exceeded for $resource ($uri), try again after $rate_limit->{resources}->{$resource}->{$uri}->{reset}" );
                    $res = 1;
                }
            }
        }
    }
    return $res;
}

sub verify_twitter_object {
    my ( $server, $win, $user, $service, $twit ) = @_;

    if ( my $timeout = $settings{timeout} and $twit->can('ua') ) {
        $twit->ua->timeout($timeout);
        &notice( ["tweet", "$user\@$service"],
                 "Twitter timeout for $user\@$service set to $timeout" );
    }

    unless ( $twit->verify_credentials() ) {
        &notice(
            [ "tweet", "$user\@$service" ],
            "Login as $user\@$service failed"
        );

        if ( not $settings{avoid_ssl} ) {
            &notice(
                [ "tweet", "$user\@$service" ],
                "It's possible you're missing one of the modules required for "
                  . "SSL logins.  Try setting twirssi_avoid_ssl to on.  See "
                  . "http://cpansearch.perl.org/src/GAAS/libwww-perl-5.831/README.SSL "
                  . "for the detailed requirements."
            );
        }

        $twit = undef;
        if ( keys %twits ) {
            &cmd_switch( ( keys %twits )[0], $server, $win );
        }
        return;
    }

    if (&rate_limited($twit, "$user\@$service")) {
        $twit = undef;
        return;
    }

    &debug("%G$user\@$service%n saving object");
    $twits{"$user\@$service"} = $twit;

    # &get_updates([ 1, [ "$user\@$service", {} ], ]);
    &ensure_updates();

    foreach my $scr_name (keys %{ $friends{"$user\@$service"} }) {
        $nicks{$scr_name} = $friends{"$user\@$service"}{$scr_name};
    }
    $nicks{$user} = 0;
    return 1;
}

sub cmd_add_follow {
    my ( $data, $server, $win ) = @_;

    unless ($data) {
        &notice( ["error"], "Usage: /twitter_add_follow_extra <username>" );
        return;
    }

    $data =~ s/^\s+|\s+$//g;
    $data =~ s/^\@//;
    $data = lc $data;

    if ( exists $state{__last_id}{"$user\@$defservice"}{__extras}{$data} ) {
        &notice( ["tweet"], "Already following all replies by \@$data" );
        return;
    }

    $state{__last_id}{"$user\@$defservice"}{__extras}{$data} = 1;
    &notice( ["tweet"], "Will now follow all replies by \@$data" );
}

sub cmd_del_follow {
    my ( $data, $server, $win ) = @_;

    unless ($data) {
        &notice( ["error"], "Usage: /twitter_del_follow_extra <username>" );
        return;
    }

    $data =~ s/^\s+|\s+$//g;
    $data =~ s/^\@//;
    $data = lc $data;

    unless ( exists $state{__last_id}{"$user\@$defservice"}{__extras}{$data} ) {
        &notice( ["error"], "Wasn't following all replies by \@$data" );
        return;
    }

    delete $state{__last_id}{"$user\@$defservice"}{__extras}{$data};
    &notice( ["tweet"], "Will no longer follow all replies by \@$data" );
}

sub cmd_list_follow {
    my ( $data, $server, $win ) = @_;

    my $found = 0;
    foreach my $suser ( sort keys %{ $state{__last_id} } ) {
        next unless exists $state{__last_id}{$suser}{__extras};
        my $frusers = join ', ', sort keys %{ $state{__last_id}{$suser}{__extras} };
        if ($frusers) {
            $found = 1;
            &notice( ["tweet"], "Following all replies as $suser: $frusers" );
        }
    }

    unless ($found) {
        &notice( ["tweet"], "Not following all replies by anyone" );
    }
}

sub cmd_add_search {
    my ( $data, $server, $win ) = @_;

    unless ( $twit and $twit->can('search') ) {
        &notice( ["search"],
                "ERROR: Your version of Net::Twitter ($Net::Twitter::VERSION) "
              . "doesn't support searches." );
        return;
    }

    my $want_win = 1 if $data =~ s/^\s*-w\s+//;

    $data =~ s/^\s+|\s+$//g;
    $data = lc $data;

    unless ($data) {
        &notice( ["search"], "Usage: /twitter_subscribe [-w] <topic>" );
        return;
    }

    if ( exists $state{__last_id}{"$user\@$defservice"}{__search}{$data} ) {
        &notice( [ "search", $data ],
            "Already had a subscription for '$data'" );
        return;
    }

    $state{__last_id}{"$user\@$defservice"}{__search}{$data} = 1;
    &notice( [ "search", $data ], "Added subscription for '$data'" );
    if ($want_win) {
        my $win_name = $data;
        $win_name =~ tr/ /+/;
        &cmd_set_window("search $data $win_name", $server, $win);
    }
}

sub cmd_del_search {
    my ( $data, $server, $win ) = @_;

    unless ( $twit and $twit->can('search') ) {
        &notice( ["search"],
                "ERROR: Your version of Net::Twitter ($Net::Twitter::VERSION) "
              . "doesn't support searches." );
        return;
    }
    $data =~ s/^\s+|\s+$//g;
    $data = lc $data;

    unless ($data) {
        &notice( ["search"], "Usage: /twitter_unsubscribe <topic>" );
        return;
    }

    unless ( exists $state{__last_id}{"$user\@$defservice"}{__search}{$data} ) {
        &notice( [ "search", $data ], "No subscription found for '$data'" );
        return;
    }

    delete $state{__last_id}{"$user\@$defservice"}{__search}{$data};
    &notice( [ "search", $data ], "Removed subscription for '$data'" );
}

sub cmd_list_search {
    my ( $data, $server, $win ) = @_;

    my $found = 0;
    foreach my $suser ( sort keys %{ $state{__last_id} } ) {
        my $topics = '';
        foreach my $topic ( sort keys %{ $state{__last_id}{$suser}{__search} } ) {
            $topics .= ($topics ne '' ? ', ' : '') . "'$topic'";
        }
        if ($topics ne '') {
            $found = 1;
            &notice( ["search"], "Search subscriptions for $suser: $topics" );
        }
    }

    unless ($found) {
        &notice( ["search"], "No search subscriptions set up" );
    }
}

sub cmd_upgrade {
    my ( $data, $server, $win ) = @_;

    my $loc = $settings{location};
    unless ( -w $loc ) {
        &notice( ["error"],
                "$loc isn't writable, can't upgrade."
              . "  Perhaps you need to /set twirssi_location?" );
        return;
    }

    my $md5;
    unless ( $data or $settings{upgrade_beta} ) {
        eval " use Digest::MD5; ";

        if ($@) {
            &notice( ["error"],
                    "Failed to load Digest::MD5."
                  . "  Try '/twirssi_upgrade nomd5' to skip MD5 verification" );
            return;
        }

        $md5 = get("http://twirssi.com/md5sum");
        chomp $md5;
        $md5 =~ s/ .*//;
        unless ($md5) {
            &notice( ["error"],
                "Failed to download md5sum from peeron!  Aborting." );
            return;
        }

        my $fh;
        unless ( open( $fh, '<', $loc ) ) {
            &notice( ["error"],
                    "Failed to read $loc."
                  . "  Check that /set twirssi_location is set to the correct location."
            );
            return;
        }

        my $cur_md5 = Digest::MD5::md5_hex(<$fh>);
        close $fh;

        if ( $cur_md5 eq $md5 ) {
            &notice( ["error"], "Current twirssi seems to be up to date." );
            return;
        }
    }

    my $URL =
      $settings{upgrade_beta}
      ? "http://github.com/$settings{upgrade_dev}/twirssi/raw/$settings{upgrade_branch}/twirssi.pl"
      : "http://twirssi.com/twirssi.pl";
    &notice( ["notice"], "Downloading twirssi from $URL" );
    LWP::Simple::getstore( $URL, "$loc.upgrade" );

    unless ( -s "$loc.upgrade" ) {
        &notice( ["error"],
                "Failed to save $loc.upgrade."
              . "  Check that /set twirssi_location is set to the correct location."
        );
        return;
    }

    unless ( $data or $settings{upgrade_beta} ) {
        my $fh;
        unless ( open( $fh, '<', "$loc.upgrade" ) ) {
            &notice( ["error"],
                    "Failed to read $loc.upgrade."
                  . "  Check that /set twirssi_location is set to the correct location."
            );
            return;
        }

        my $new_md5 = Digest::MD5::md5_hex(<$fh>);
        close $fh;

        if ( $new_md5 ne $md5 ) {
            &notice( ["error"],
                "MD5 verification failed. expected $md5, got $new_md5" );
            return;
        }
    }

    rename $loc, "$loc.backup"
      or &notice( ["error"], "Failed to back up $loc: $!.  Aborting" )
      and return;
    rename "$loc.upgrade", $loc
      or &notice( ["error"], "Failed to rename $loc.upgrade: $!.  Aborting" )
      and return;

    my ( $dir, $file ) = ( $loc =~ m{(.*)/([^/]+)$} );
    if ( -e "$dir/autorun/$file" ) {
        &notice( ["notice"], "Updating $dir/autorun/$file" );
        unlink "$dir/autorun/$file"
          or
          &notice( ["error"], "Failed to remove old $file from autorun: $!" );
        symlink "../$file", "$dir/autorun/$file"
          or &notice( ["error"],
            "Failed to create symlink in autorun directory: $!" );
    }

    &notice( ["notice"],
        "Download complete.  Reload twirssi with /twirssi_reload" );
}

sub cmd_list_channels {
    my ( $data, $server, $win ) = @_;

    &notice("Current output channels:");
    foreach my $type ( sort keys %{ $state{__channels} } ) {
        &notice("$type:");
        foreach my $tag ( sort keys %{ $state{__channels}{$type} } ) {
            &notice("  $tag:");
            foreach my $net_tag ( sort keys %{ $state{__channels}{$type}{$tag} } ) {
                &notice("    $net_tag: "
                        . join ', ', @{ $state{__channels}{$type}{$tag}{$net_tag} });
            }
        }
    }
    &notice("Add new entries using /twirssi_set_channel "
          . "[[-]type|*] [account|search_term|*] [net_tag] [channel]" );
    &notice("Type can be one of: tweet, reply, dm, search, sender, error.",
                "A '*' for type/tag indicates wild"
                    . "  (if type is wild, ensure account qualified: [user]\@[service]).",
                "Remove settings by negating type, e.g. '-tweet'.");
}

sub cmd_set_channel {
    my ( $data, $server, $win ) = @_;

    my @words = split ' ', lc $data;
    unless (@words == 4) {
        return &cmd_list_channels(@_);
    }

    my ($type, $tag, $net_tag, $channame) = @words;
    my $delete = 1 if $type =~ s/^-//;

    unless ( grep { $type eq $_ } @{ $valid_types{'channel'} } ) {
        &notice(['error'], "Invalid message type '$type'.");
        &notice(['error'], 'Valid types: ' . join(', ', @{ $valid_types{'channel'} }));
        return;
    }

    $tag = &normalize_username($tag) unless grep { $type eq $_ } qw/ search sender * /
                or $tag eq '*';

    if ($delete) {
        if (not defined $state{__channels}{$type}
                or not defined $state{__channels}{$type}{$tag}
                or not defined $state{__channels}{$type}{$tag}{$net_tag}
                or not grep { $_ eq $channame } @{ $state{__channels}{$type}{$tag}{$net_tag} }) {
            &notice("No such channel setting for $type/$tag on $net_tag.");
            return;
        }
        &notice("$type/$tag messages will no longer be sent"
              . " to the '$channame' channel on $net_tag" );
        @{ $state{__channels}{$type}{$tag}{$net_tag} } =
            grep { $_ ne $channame } @{ $state{__channels}{$type}{$tag}{$net_tag} };
        delete $state{__channels}{$type}{$tag}{$net_tag}
          unless @{ $state{__channels}{$type}{$tag}{$net_tag} };
        delete $state{__channels}{$type}{$tag}
          unless keys %{ $state{__channels}{$type}{$tag} };
        delete $state{__channels}{$type}
          unless keys %{ $state{__channels}{$type} };

    } elsif (defined $state{__channels}{$type}{$tag}{$net_tag}
                and grep { $_ eq $channame }
                      @{ $state{__channels}{$type}{$tag}{$net_tag} }) {
        &notice("There is already such a channel setting.");
        return;

    } else {
        &notice("$type/$tag messages will now be sent"
              . " to the '$channame' channel on $net_tag" );
        push @{ $state{__channels}{$type}{$tag}{$net_tag} }, $channame;
    }

    &save_state();
    return;
}

sub cmd_list_windows {
    my ( $data, $server, $win ) = @_;

    &notice("Current output windows:");
    foreach my $type ( sort keys %{ $state{__windows} } ) {
        &notice("$type:");
        foreach my $tag ( sort keys %{ $state{__windows}{$type} } ) {
            &notice("  $tag: $state{__windows}{$type}{$tag}");
        }
    }
    &notice( "Default window for all other messages: " . $settings{window} );

    &notice("Add new entries with the /twirssi_set_window "
          . "[type] [tag] [window] command." );
    &notice("Remove a setting by setting window name to '-'.");
}

sub cmd_set_window {
    my ( $data, $server, $win ) = @_;

    my @words = split ' ', $data;

    unless (@words) {
        &cmd_list_windows(@_);
        return;
    }

    my $winname = pop @words;       # the last argument is the window name
    my $delete = $winname eq '-';

    if ( @words == 0 ) {            # just a window name
        $winname = 'twitter' if $delete;
        &notice("Changing the default twirssi window to $winname");
        Irssi::settings_set_str( "twitter_window", $winname );
        &ensure_logfile($settings{window} = $winname);
     } elsif ( @words > 2 and $words[0] ne 'search' ) {
        &notice(
                "Too many arguments to /twirssi_set_window. '@words'",
                "Usage: /twirssi_set_window [type] [account|search_term] [window].",
                'Valid types: ' . join(', ', @{ $valid_types{'window'} })
        );
        return;
    } elsif ( @words >= 1 ) {
        my $type = lc $words[0];
        unless ( grep { $_ eq $type } @{ $valid_types{'window'} } ) {
            &notice(['error'],
                "Invalid message type '$type'.",
                'Valid types: ' . join(', ', @{ $valid_types{'window'} })
            );
            return;
        }

        my $tag = "default";
        if ( @words >= 2 ) {
           $tag = lc $words[1];
           if ($type eq 'sender') {
              $tag =~ s/^\@//;
              $tag =~ s/\@.+//;
           } elsif ($type ne 'search'
                   and ($type ne 'default' or index($tag, '@') >= 0)
                   and $tag ne 'default') {
              $tag = &normalize_username($tag);
           } elsif ($type eq 'search' and @words > 2) {
              $tag = lc join(' ', @words[1..$#words]);
           }
           if (substr($tag, -1, 1) eq '@') {
              &notice(['error'], "Invalid tag '$tag'.");
              return;
           }
        }

        if ($delete) {
            if (not defined $state{__windows}{$type}
                     or not defined $state{__windows}{$type}{$tag}) {
               &notice("No such window setting for $type/$tag.");
               return;
            }
            &notice("$type/$tag messages will no longer be sent to the '"
                       . $state{__windows}{$type}{$tag} . "' window" );
            delete $state{__windows}{$type}{$tag};
            delete $state{__windows}{$type}
              unless keys %{ $state{__windows}{$type} };
        } else {
            &notice("$type/$tag messages will now"
                  . " be sent to the '$winname' window" );
            $state{__windows}{$type}{$tag} = $winname;
        }

        &save_state();
    }

    &ensure_window($winname) if $winname ne '-';

    return;
}

sub get_friends {
    my $u_twit    = shift;
    my $username  = shift;
    my $fh        = shift;
    my $is_update = shift;

    my $new_friends = &scan_cursor('friends', $u_twit, $username, $fh,
				{ fn=>'friends', cp=>(index($username, '@Twitter') != -1 ? 'c' : 'p'),
					set_key=>'users', item_key=>'screen_name', });
    return if not defined $new_friends;

    return $new_friends if not $is_update;

    my ( $added, $removed ) = ( 0, 0 );
    # &debug($fh, "%G$username%n Scanning for new friends...");
    foreach ( keys %$new_friends ) {
        next if exists $friends{$username}{$_};
        $friends{$username}{$_} = $new_friends->{$_};
        $added++;
    }

    # &debug($fh, "%G$username%n Scanning for removed friends...");
    foreach ( keys %{ $friends{$username} } ) {
        next if exists $new_friends->{$_};
        delete $friends{$username}{$_};
        &debug($fh, "%G$username%n removing friend: $_");
        $removed++;
    }

    return ( $added, $removed );
}

sub scan_cursor {
    my $type_str  = shift;
    my $u_twit    = shift;
    my $username  = shift;
    my $fh        = shift;
    my $fn_info   = shift;

    my $whole_set = {};
    my $paging_broken = 0;
    my $fn_args = { (defined $fn_info->{args} ? %{ $fn_info->{args} } : ()) };
    my $fn_name = $fn_info->{fn};
    eval {
        for (my $cursor = -1, my $page = 1; $cursor and $page <= 10 and not $paging_broken; $page++) {
            if (-1 != index($fn_info->{cp}, 'c')) {
                $fn_args->{cursor} = $cursor;
            }
            if ($fn_info->{cp} =~ /p(\d*)/) {
                my $max_page = $1;
                $fn_args->{page} = $page;
                last if length($max_page) > 0 and $page > $max_page;
            }
            &debug($fh, "%G$username%n Loading $type_str page $page...");
            my $collection = $u_twit->$fn_name($fn_args);
            last unless $collection;
            if (-1 != index($fn_info->{cp}, 'c')) {
                $cursor = $collection->{next_cursor};
                $collection = $collection->{$fn_info->{set_key}};
            }
            foreach my $coll_item (@$collection) {
                if (-1 != index($fn_info->{cp}, 'p')
                       and defined $whole_set->{$coll_item->{$fn_info->{item_key}}}) {
                    # fix broken paging, as we've seen this $coll_item before
                    $paging_broken = 1;
                    last;
                }
                $whole_set->{$coll_item->{$fn_info->{item_key}}} = (defined $fn_info->{item_val}
								? $coll_item->{$fn_info->{item_val}} : time);
            }
        }
    };
foreach my $item (split "\n", Dumper($whole_set)) { &debug($fh, "crsr: $item"); }

    if ($@) {
        &notice(['error', $username, $fh], "$username: Error updating $type_str.  Aborted.");
        &debug($fh, "%G$username%n Error updating $type_str: $@");
        return;
    }

   return $whole_set;
}

sub get_lists {
    my $u_twit    = shift;
    my $username  = shift;
    my $fh        = shift;
    my $is_update = shift;
    my $userid    = shift;
    my $list_name = shift;

    my $list_account = $username;
    if ($is_update and not defined $userid and $username =~ /(.+)\@/) {
      $userid = $1;
    } else {
      $list_account = &normalize_username($userid, 1);
    }

    my %stats = (added => 0, deleted => 0);

    # ensure $new_lists->{$list_name} = $id
    my %more_args = ();
    my $new_lists = &scan_cursor('lists', $u_twit, $username, $fh,
				{ fn=>'get_lists', cp=>'', set_key=>'lists',
					args=>{ user=>$userid, %more_args }, item_key=>'name', item_val=>'id', });
    return if not defined $new_lists;

    # reduce $new_lists if $list_name specified (not $is_update)
    if (defined $list_name) {
        if (not defined $new_lists->{$list_name}) {
            return {};  # not is_update, so return empty
        }
        $new_lists = { $list_name => $new_lists->{$list_name} };
    }

    foreach my $list (keys %$new_lists) {
        $stats{added}++ if not exists $state{__lists}{$list_account}{$list};
        $state{__lists}{$list_account}{$list} = { id=>$new_lists->{$list}, members=>[], };
    }

    if ($is_update) {
        # remove any newly-missing lists
        foreach my $old_list (keys %{ $state{__lists}{$list_account} }) {
            if (not defined $new_lists->{$old_list}) {
                delete $state{__lists}{$list_account}{$old_list};
                &debug($fh, "%G$username%n removing list: $list_account / $old_list");
                $stats{deleted}++;
            }
        }
    }

    foreach my $reget_list (keys %$new_lists) {
        &debug($fh, "%G$username%n updating list: $list_account / $reget_list id=" .
                        $state{__lists}{$list_account}{$reget_list}{id});
        my $members = &scan_cursor('list member', $u_twit, $username, $fh,
			{ fn=>'list_members', cp=>'c', set_key=>'users', item_key=>'screen_name', item_val=>'id',
				args=>{ user=>$userid, list_id=>$state{__lists}{$list_account}{$reget_list}{id} }, });
        return if not defined $members;
        $state{__lists}{$list_account}{$reget_list}{members} = [ keys %$members ];
    }

    return ($stats{added}, $stats{deleted});
}

sub get_blocks {
    my $u_twit    = shift;
    my $username  = shift;
    my $fh        = shift;
    my $is_update = shift;

    my $new_blocks = &scan_cursor('blocks', $u_twit, $username, $fh,
				{ fn=>'blocking', cp=>'c', set_key=>'users', item_key=>'screen_name', });
    return if not defined $new_blocks;

    return $new_blocks if not $is_update;

    my ( $added, $removed ) = ( 0, 0 );
    # &debug($fh, "%G$username%n Scanning for new blocks...");
    foreach ( keys %$new_blocks ) {
        next if exists $blocks{$username}{$_};
        $blocks{$username}{$_} = time;
        $added++;
    }

    # &debug($fh, "%G$username%n Scanning for removed blocks...");
    foreach ( keys %{ $blocks{$username} } ) {
        next if exists $new_blocks->{$_};
        delete $blocks{$username}{$_};
        &debug($fh, "%G$username%n removing block: $_");
        $removed++;
    }

    return ( $added, $removed );
}

sub get_reply_to {
    # extract reply-to-information from tweets
    my $t = shift;

    if ($t->{in_reply_to_screen_name}
       and $t->{in_reply_to_status_id}) {
       return sprintf 'reply_to_user:%s reply_to_id:%s ',
           $t->{in_reply_to_screen_name},
           $t->{in_reply_to_status_id};
    } else {
       return '';
    }
}

sub cmd_wipe {
    my ( $data, $server, $win ) = @_;
    my @cache_keys = qw/ __tweets __indexes __ids
			__usernames __reply_to_ids __reply_to_users __created_ats /;
    my @surplus_nicks = ();
    if ($data eq '') {
        for my $nick (keys %{ $state{__tweets} }) {
            my $followed = 0;
            for my $acct (keys %twits) {
                if (grep { lc($_) eq $nick } keys %{ $friends{$acct} }) {
                    $followed = 1;
                    last;
                }
            }
            push @surplus_nicks, $nick if not $followed;
        }
    } else {
        for my $to_wipe (split(/\s+/, $data)) {
            if (exists $state{$to_wipe}) {
                &notice("Wiping '$to_wipe' state.");
                $state{$to_wipe} = {};
            } elsif ($to_wipe eq '-f') {
                push @surplus_nicks, keys %{ $state{__tweets} };
            } elsif ($to_wipe eq '-A') {
                &notice('Wiping all info/settings.');
                %state = ();
            } else {
                &notice([ 'error' ], "Error: no such twirssi_wipe argument '$to_wipe'.");
            }
        }
    }
    if (@surplus_nicks) {
        for my $surplus_nick (@surplus_nicks) {
            for my $cache_key (@cache_keys) {
                delete $state{$cache_key}{$surplus_nick};
            }
        }
        &debug('Wiped data for ' . join(',', @surplus_nicks));
        &notice('Wiped data for ' . (0+@surplus_nicks) . ' nicks.');
    }
}

sub cmd_user {
    my $target = shift;
    my $server = shift;
    my $win = shift;
    $target =~ s/(?::\d+)?\s*$//;
    &cmd_set_window("sender $target $target", $server, $win)
                        if $target =~ s/^\s*-w\s+// and $target ne '';
    &get_updates([ 0, [
                            [ "$user\@$defservice", { up_user => $target } ],
                      ],
    ]);
}

sub tweet_to_meta {
    my $obj      = shift;
    my $t        = shift;
    my $username = shift;
    my $type     = shift;
    my $topic    = shift;
    my %meta     = (
        username => $username,
        type     => $type,
        nick     => ($type eq 'dm' ? $t->{sender_screen_name}
                                    : $t->{user}{screen_name}),
    );
    ($meta{account}, $meta{service}) = split('@', $username, 2);
    foreach my $meta_key (keys %meta_to_twit) {
        $meta{$meta_key} = $t->{$meta_to_twit{$meta_key}} if defined $t->{$meta_to_twit{$meta_key}};
    }
    $meta{created_at} = &date_to_epoch($meta{created_at});
    $meta{topic} = $topic if defined $topic;
    $meta{text} = &get_text($t, $obj);
    return \%meta;
}

sub tweet_or_reply {
    my $obj      = shift;
    my $t        = shift;
    my $username = shift;
    my $cache    = shift;
    my $fh       = shift;

    my $type = 'tweet';
    if ( $t->{in_reply_to_screen_name}
        and $username !~ /^\Q$t->{in_reply_to_screen_name}\E\@/i
        and not exists $friends{$username}{ $t->{in_reply_to_screen_name} } ) {
        $nicks{ $t->{in_reply_to_screen_name} } = time;
        unless ( $cache->{ $t->{in_reply_to_status_id} } ) {
            eval {
                $cache->{ $t->{in_reply_to_status_id} } =
                  $obj->show_status( $t->{in_reply_to_status_id} );
            };
        }
&debug($fh, "REPLY $username rep2 $@ " . Dumper($cache->{ $t->{in_reply_to_status_id} }));
        if (my $t_reply = $cache->{ $t->{in_reply_to_status_id} }) {
            if (defined $fh) {
                my $ctext = &get_text( $t_reply, $obj );
                printf $fh "t:tweet id:%s ac:%s %snick:%s created_at:%s %s\n",
                  $t_reply->{id}, $username, &get_reply_to($t_reply),
                  $t_reply->{user}{screen_name},
                  &encode_for_file($t_reply->{created_at}),
                  $ctext;
                &get_unshorten_urls($ctext, $fh);
            }
            $type = 'reply';
        }
    }
    return $type;
}

sub background_setup {
    my $pause_monitor = shift || 5000;
    my $max_pauses    = shift || 24;
    my $is_update     = shift;
    my $fn_to_call    = shift;
    my $fn_args_ref   = shift;

    &debug("bg_setup starting upd=$is_update");

    return unless &logged_in($twit);

    my ( $fh, $filename ) = File::Temp::tempfile('tw_'.$$.'_XXXX', TMPDIR => 1);
    my $done_filename = "$filename.done";
    unlink($done_filename) if -f $done_filename;
    binmode( $fh, ":" . &get_charset() );
    $child_pid = fork();

    if ($child_pid) {                   # parent
        Irssi::timeout_add_once( $pause_monitor, 'monitor_child',
            [ $done_filename, $max_pauses, $pause_monitor, $is_update, $filename . '.' . $child_pid, 0 ] );
        Irssi::pidwait_add($child_pid);
    } elsif ( defined $child_pid ) {    # child
        my $pid_filename = $filename . '.' . $$;
        rename $filename, $pid_filename;
        close STDIN;
        close STDOUT;
        close STDERR;

        {
            no strict 'refs';
            &$fn_to_call($fh, @$fn_args_ref);
        }

        close $fh;
        rename $pid_filename, $done_filename;
        exit;
    } else {
        &notice([ 'error' ], "Failed to fork for background call: $!");
    }
}

sub ensure_updates {
    my $adhoc_interval = shift;
    my $poll_interval = (defined $adhoc_interval ? $adhoc_interval : &get_poll_time) * 1000;
    if ($poll_interval != $last_poll{__interval} or not $poll_event) {
        &debug("get_updates every " . int($poll_interval/1000));
        Irssi::timeout_remove($poll_event) if $poll_event;
        $poll_event = Irssi::timeout_add( $poll_interval, \&get_updates, [ 1 ] );
        $last_poll{__interval} = $poll_interval;
    }
}

sub get_updates {
    my $args = shift;

    my $is_regular = 0;
    my $to_be_updated;
    if (not ref $args) {	# command-line request, so do regular
        $is_regular = 1;
    } else {
        $is_regular    = $args->[0];
        $to_be_updated = $args->[1];
    }

    &debug("get_updates starting upd=$is_regular");

    return unless &logged_in($twit);

    if ($is_regular) {
        if ($update_is_running) {
            &debug("get_updates aborted: already running");
            return;
        }
        $update_is_running = 1;
    }

    if (not defined $to_be_updated) {
        $to_be_updated = [];
        foreach my $pref_user (@{ $settings{update_usernames} }) {
            next unless $pref_user = &valid_username($pref_user);
            next if grep { $_ eq $pref_user } @{ $settings{ignored_accounts} };
            push @$to_be_updated, [ $pref_user, {} ];
        }
        foreach my $other_user (keys %twits) {
            next if grep { $_ eq $other_user } @{ $settings{ignored_accounts} };
            push @$to_be_updated, [ $other_user, {} ]
                 if not grep { $other_user eq $_->[0] } @$to_be_updated;
        }
    }
    &background_setup(5000, (24*@$to_be_updated), $is_regular, 'get_updates_child', [ $is_regular, $to_be_updated ]);

    if ($is_regular) {
        &ensure_updates();
    }
}

sub get_updates_child {
    my $fh            = shift;
    my $is_regular    = shift;
    my $to_be_updated = shift;

    my $time_before_update = time;

    my $error = 0;
    my @error_types = ();
    my %context_cache;

    foreach my $update_tuple ( @$to_be_updated ) {
        my $username       = shift @$update_tuple;
        my $what_to_update = shift @$update_tuple;
        my $errors_beforehand = $error;

        if (0 == keys(%$what_to_update)
                or defined $what_to_update->{up_tweets}) {
            unless (&get_tweets( $fh, $username, $twits{$username}, \%context_cache )) {
                $error++;
                push @error_types, 'tweets';
            }

            if ( exists $state{__last_id}{$username}{__extras}
                    and keys %{ $state{__last_id}{$username}{__extras} } ) {
                my @frusers = sort keys %{ $state{__last_id}{$username}{__extras} };

                unless (&get_timeline( $fh, $frusers[ $fix_replies_index{$username} ],
                                               $username, $twits{$username}, \%context_cache, $is_regular )) {
                    $error++;
                    push @error_types, 'replies';
                }

                $fix_replies_index{$username}++;
                $fix_replies_index{$username} = 0
                      if $fix_replies_index{$username} >= @frusers;
                print $fh "t:fix_replies_index idx:$fix_replies_index{$username} ",
                      "ac:$username\n";
            }
        }
        next if $error > $errors_beforehand;

        if (defined $what_to_update->{up_user}) {
            unless (&get_timeline( $fh, $what_to_update->{up_user},
                                               $username, $twits{$username}, \%context_cache, $is_regular )) {
                $error++;
                push @error_types, 'tweets';
            }

        }
        next if $error > $errors_beforehand;

        if (0 == keys(%$what_to_update)
                    or defined $what_to_update->{up_dms}) {
            unless (&do_dms( $fh, $username, $twits{$username}, $is_regular )) {
                $error++;
                push @error_types, 'dms';
            }
        }
        next if $error > $errors_beforehand;

        if (0 == keys(%$what_to_update)
                    or defined $what_to_update->{up_subs}) {
            unless (&do_subscriptions( $fh, $username, $twits{$username}, $what_to_update->{up_subs} )) {
                $error++;
                push @error_types, 'subs';
            }
        }
        next if $error > $errors_beforehand;

        if (0 == keys(%$what_to_update)
                    or defined $what_to_update->{up_searches}) {
            unless (&do_searches( $fh, $username, $twits{$username}, $what_to_update->{up_searches} )) {
                $error++;
                push @error_types, 'searches';
            }
        }
        next if $error > $errors_beforehand;

        if ( (0 == keys(%$what_to_update)
                  and time - $last_poll{$username}{friends} > $settings{friends_poll})
                or defined $what_to_update->{up_friends} ) {
            my $show_friends;
            if ($is_regular) {
                my $time_before = time;
                my ( $added, $removed ) = &get_friends($twits{$username}, $username, $fh, 1);
                print $fh "t:debug %G$username%n Friends list updated: ",
                        "$added added, $removed removed\n" if $added + $removed;
                print $fh "t:last_poll ac:$username poll_type:friends epoch:$time_before\n";
                $show_friends = $friends{$username};
            } else {
                $show_friends = &get_friends($twits{$username}, $username, $fh, 0);
            }
            foreach ( sort keys %$show_friends ) {
                print $fh "t:friend ac:$username nick:$_ epoch:$show_friends->{$_}\n";
            }
        }
        next if $error > $errors_beforehand;

        if ( (0 == keys(%$what_to_update)
                  and time - $last_poll{$username}{blocks} > $settings{blocks_poll} )
                or defined $what_to_update->{up_blocks}) {
            my $show_blocks;
            if ($is_regular) {
                my $time_before = time;
                my ( $added, $removed ) = &get_blocks($twits{$username}, $username, $fh, 1);
                print $fh "t:debug %G$username%n Blocks list updated: ",
                        "$added added, $removed removed\n" if $added + $removed;
                print $fh "t:last_poll ac:$username poll_type:blocks epoch:$time_before\n";
                $show_blocks = $blocks{$username};
            } else {
                $show_blocks = &get_blocks($twits{$username}, $username, $fh, 0);
            }
            foreach ( sort keys %$show_blocks ) {
                print $fh "t:block ac:$username nick:$_ epoch:$show_blocks->{$_}\n";
            }
        }
        next if $error > $errors_beforehand;

        if ( (0 == keys(%$what_to_update)
                  and time - $last_poll{$username}{lists} > $settings{lists_poll} )
                or defined $what_to_update->{up_lists}) {
            my $list_account = $username;
            my $list_name_limit;
            if ($is_regular) {
                my $time_before = time;
                my ( $added, $removed ) = &get_lists($twits{$username}, $username, $fh, 1);
                print $fh "t:debug %G$username%n Lists list updated: ",
                        "$added added, $removed removed\n" if $added or $removed;
                print $fh "t:last_poll ac:$username poll_type:lists epoch:$time_before\n";
            } else {
                if (defined $what_to_update->{up_lists} and ref $what_to_update->{up_lists}
                        and defined $what_to_update->{up_lists}->[0]) {
                    $list_account = &normalize_username($what_to_update->{up_lists}->[0], 1);
                    if (defined $what_to_update->{up_lists}->[1]) {
                        $list_name_limit = $what_to_update->{up_lists}->[1];
                    }
                }
                if (not defined &get_lists($twits{$username}, $username, $fh, 0, @{ $what_to_update->{up_lists} })) {
                    &debug($fh, "%G$username%n Polling for lists failed.");
                    $error++;
                    push @error_types, 'lists';
                }
            }
            if (not defined $state{__lists}{$list_account}) {
                &notice(['info', undef, $fh], "List owner $list_account does not exist or has no lists.")
                    if not $is_regular;
            } elsif (defined $list_name_limit and not defined $state{__lists}{$list_account}{$list_name_limit}) {
                &notice(['info', undef, $fh], "List $list_account/$list_name_limit does not exist.")
                    if not $is_regular;
            } else {
                foreach my $list_name (sort keys %{ $state{__lists}{$list_account} }) {
                    next if defined $list_name_limit and $list_name ne $list_name_limit;
                    my $list_id = $state{__lists}{$list_account}{$list_name}{id};
                    foreach my $member ( @{ $state{__lists}{$list_account}{$list_name}{members} } ) {
                        print $fh "t:list ac:$username list:$list_account/$list_name id:$list_id nick:$member\n";
                    }
                }
            }
        }
        next if $error > $errors_beforehand;
    }

    &put_unshorten_urls($fh, $time_before_update);

    if ($error) {
        &notice( [ 'error', undef, $fh ], "Update encountered errors (@error_types).  Aborted");
        &notice( [ 'error', undef, $fh ], "For recurring DMs errors, please re-auth (delete $settings{oauth_store})") if grep { $_ eq 'dms' } @error_types;
    } elsif ($is_regular) {
        print $fh "t:last_poll poll_type:__poll epoch:$time_before_update\n";
    }
}

sub is_ignored {
    my $text = shift;
    my $twit = shift;

    my $text_no_colors = &remove_colors($text);
    foreach my $tag (@{ $settings{ignored_tags} }) {
        return $tag if $text_no_colors =~ /(?:^|\b|\s)\Q$tag\E(?:\b|\s|$)/i;
    }
    if (defined $twit and grep { $_ eq lc $twit } @{ $settings{ignored_twits} }) {
        return $twit;
    }
    return undef;
}

sub remove_tags {
    my $text = shift;

    foreach my $tag (@{ $settings{stripped_tags} }) {
        $text =~ s/\cC\d{2}\Q$tag\E\cO//gi;   # with then without colors
        $text =~ s/(^|\b|\s)\Q$tag\E(\b|\s|$)/$1$2/gi;
    }
    return $text;
}

sub get_tweets {
    my ( $fh, $username, $obj, $cache ) = @_;

    return if &rate_limited($obj, $username, $fh);

    &debug($fh, "%G$username%n Polling for tweets");
    my $tweets = [];
    eval {
        my %call_attribs = ( page => 1 );
        $call_attribs{count} = $settings{track_replies} if $settings{track_replies};
        $call_attribs{since_id} = $state{__last_id}{$username}{timeline}
                           if defined $state{__last_id}{$username}{timeline};
        for ( ; $call_attribs{page} < 2 ; $call_attribs{page}++) {
            &debug($fh, "%G$username%n timeline " . join(' ', map { $_ . '=' . $call_attribs{$_} } sort keys %call_attribs));
            my $page_tweets = $obj->home_timeline( \%call_attribs );
            last if not defined $page_tweets or @$page_tweets == 0;
            unshift @$tweets, @$page_tweets;
        }
    };

    if ($@) {
        print $fh "t:error $username Error during home_timeline call: Aborted.\n";
        print $fh "t:debug : $_\n" foreach split /\n/, Dumper($@);
        return;
    }


=pod

    unless ( ref $tweets ) {
        if ( $obj->can("get_error") ) {
            my $error = "Unknown error";
            eval { $error = JSON::Any->jsonToObj( $obj->get_error() ) };
            unless ($@) { $error = $obj->get_error() }
            &notice([ 'error', $username, $fh],
                "$username: API Error during home_timeline call: Aborted");
            print $fh "t:debug : $_\n" foreach split /\n/, Dumper($error);

        } else {
            &notice([ 'error', $username, $fh],
                "$username: API Error in home_timeline call. Aborted.");
        }
        return;
    }

=cut

    print $fh "t:debug %G$username%n got ", scalar(@$tweets), ' tweets',
		(@$tweets	? ', first/last: ' . join('/',
						(sort {$a->{id} <=> $b->{id}} @$tweets)[0]->{id},
						(sort {$a->{id} <=> $b->{id}} @$tweets)[$#{$tweets}]->{id}
					)
				: ''),
		"\n";

    my $new_poll_id = 0;
    my @own_ids = ();
    foreach my $t ( reverse @$tweets ) {
        my $text = &get_text( $t, $obj );
        $text = &remove_tags($text);
        my $ign = &is_ignored($text, $t->{user}{screen_name});
        $ign = (defined $ign ? 'ign:' . &encode_for_file($ign) . ' ' : '');
        my $reply = &tweet_or_reply($obj, $t, $username, $cache, $fh);
        if ($t->{user}{screen_name} eq $username and not $settings{own_tweets}) {
            push @own_ids, $t->{id};
            next;
        }
        printf $fh "t:%s id:%s ac:%s %s%snick:%s created_at:%s %s\n",
            $reply, $t->{id}, $username, $ign, &get_reply_to($t), $t->{user}{screen_name},
            &encode_for_file($t->{created_at}), $text;
        &get_unshorten_urls($text, $fh);

        $new_poll_id = $t->{id} if $new_poll_id < $t->{id};
    }
    &debug($fh, "%G$username%n skip own " . join(', ', @own_ids) . "\n") if @own_ids;
    printf $fh "t:last_id id:%s ac:%s id_type:timeline\n", $new_poll_id, $username if $new_poll_id;

    &debug($fh, "%G$username%n Polling for replies since " . $state{__last_id}{$username}{reply});
    eval {
        if ( $state{__last_id}{$username}{reply} ) {
            $tweets = $obj->replies( { since_id => $state{__last_id}{$username}{reply} } )
                      || [];
        } else {
            $tweets = $obj->replies() || [];
        }
    };

    if ($@) {
        print $fh "t:debug %G$username%n Error during replies call.  Aborted.\n";
        &debug($fh, "%G$username%n Error: " . $@);
        return;
    }

    $new_poll_id = 0;
    foreach my $t ( reverse @$tweets ) {
        next if exists $friends{$username}{ $t->{user}{screen_name} };

        my $text = &get_text( $t, $obj );
        $new_poll_id = $t->{id} if $new_poll_id < $t->{id};
        $text = &remove_tags($text);
        &get_unshorten_urls($text, $fh);
        my $ign = &is_ignored($text);
        $ign = (defined $ign ? 'ign:' . &encode_for_file($ign) . ' ' : '');
        printf $fh "t:tweet id:%s ac:%s %s%snick:%s created_at:%s %s\n",
          $t->{id}, $username, $ign, &get_reply_to($t), $t->{user}{screen_name},
          &encode_for_file($t->{created_at}), $text;
    }
    printf $fh "t:last_id id:%s ac:%s id_type:reply\n", $new_poll_id, $username if $new_poll_id;
    return 1;
}


sub do_dms {
    my ( $fh, $username, $obj, $is_regular ) = @_;

    my $new_poll_id = 0;

    my $since_args = {};
    if ( $is_regular and $state{__last_id}{$username}{dm} ) {
        $since_args->{since_id} = $state{__last_id}{$username}{dm};
        &debug($fh, "%G$username%n Polling for DMs since_id " .
                         $state{__last_id}{$username}{dm});
    } else {
        &debug($fh, "%G$username%n Polling for DMs");
    }

    my $tweets;
    eval {
        $tweets = $obj->direct_messages($since_args) || [];
    };
    if ($@) {
        &debug($fh, "%G$username%n Error during direct_messages call.  Aborted.");
        &debug($fh, "%G$username%n Error: " . $@);
        return;
    }
    &debug($fh, "%G$username%n got DMs: " . (0+@$tweets));

    foreach my $t ( reverse @$tweets ) {
        my $text = decode_entities( $t->{text} );
        $text =~ s/[\n\r]/ /g;
        printf $fh "t:dm id:%s ac:%s %snick:%s created_at:%s %s\n",
          $t->{id}, $username, &get_reply_to($t), $t->{sender_screen_name},
          &encode_for_file($t->{created_at}), $text;
        $new_poll_id = $t->{id} if $new_poll_id < $t->{id};
    }
    printf $fh "t:last_id id:%s ac:%s id_type:dm\n", $new_poll_id, $username if $new_poll_id;
    return 1;
}

sub do_subscriptions {
    my ( $fh, $username, $obj, $search_limit ) = @_;

    &debug($fh, "%G$username%n Polling for subscriptions");
    if ( $obj->can('search') and $state{__last_id}{$username}{__search} ) {
        my $search;
        foreach my $topic ( sort keys %{ $state{__last_id}{$username}{__search} } ) {
            next if defined $search_limit and @$search_limit and not grep { $topic eq $_ } @$search_limit;
            print $fh "t:debug %G$username%n Search '$topic' id was ",
              "$state{__last_id}{$username}{__search}{$topic}\n";
            eval {
                $search = $obj->search(
                    {
                        q        => $topic,
                        since_id => $state{__last_id}{$username}{__search}{$topic}
                    }
                );
            };

            if ($@) {
                print $fh
                  "t:debug %G$username%n Error during search($topic) call.  Aborted.\n";
                &debug($fh, "%G$username%n Error: " . $@);
                return;
            }

            unless ( $search->{search_metadata}->{max_id} ) {
                print $fh "t:debug %G$username%n Invalid search results when searching",
                  " for '$topic'. Aborted.\n";
                return;
            }

            $state{__last_id}{$username}{__search}{$topic} = $search->{search_metadata}->{max_id};
            printf $fh "t:searchid id:%s ac:%s topic:%s\n",
              $search->{search_metadata}->{max_id}, $username, &encode_for_file($topic);

            foreach my $t ( reverse @{ $search->{statuses} } ) {
                next if exists $blocks{$username}{ $t->{user}->{screen_name} };
                my $text = &get_text( $t, $obj );
                $text = &remove_tags($text);
                my $ign = &is_ignored($text, $t->{user}->{screen_name});
                &get_unshorten_urls($text, $fh);
                $ign = (defined $ign ? 'ign:' . &encode_for_file($ign) . ' ' : '');
                printf $fh "t:search id:%s ac:%s %snick:%s topic:%s created_at:%s %s\n",
                  $t->{id}, $username, $ign, $t->{user}->{screen_name}, &encode_for_file($topic),
                  &encode_for_file($t->{created_at}), $text;
            }
        }
    }
    return 1;
}

sub do_searches {
    my ( $fh, $username, $obj, $search_limit ) = @_;

    &debug($fh, "%G$username%n Polling for one-time searches");
    if ( $obj->can('search') and exists $search_once{$username} ) {
        my $search;
        foreach my $topic ( sort keys %{ $search_once{$username} } ) {
            next if defined $search_limit and @$search_limit and not grep { $topic eq $_ } @$search_limit;
            my $max_results = $search_once{$username}->{$topic};

            $topic = &make_utf8($topic);

            print $fh
              "t:debug %G$username%n search $topic once (max $max_results)\n";
            eval { $search = $obj->search( { 'q' => $topic } ); };

            if (my $err = $@) {
                $err = $err->error . ' (' . $err->code . ' ' . $err->message . ')' if ref($err) eq 'Net::Twitter::Error';
                print $fh "t:debug %G$username%n Error during search_once($topic) call.  Aborted.\n";
                &debug($fh, "%G$username%n Error: $err");
                return;
            }

            unless ( $search->{search_metadata}->{max_id} ) {
                print $fh "t:debug %G$username%n Invalid search results when searching once",
                  " for $topic. Aborted.\n";
                return;
            }

            # TODO: consider applying ignore-settings to search results
            my @results = ();
            foreach my $res (@{ $search->{statuses} }) {
                if (exists $blocks{$username}{ $res->{user}->{screen_name} }) {
                    print $fh "t:debug %G$username%n blocked $topic: $res->{user}->{screen_name}\n";
                    next;
                }
                push @results, $res;
            }
            if ( $max_results > 0 ) {
                splice @results, $max_results;
            }
            foreach my $t ( reverse @results ) {
                my $text = &get_text( $t, $obj );
                $text = &remove_tags($text);
                &get_unshorten_urls($text, $fh);
                my $ign = &is_ignored($text, $t->{user}->{screen_name});
                $ign = (defined $ign ? 'ign:' . &encode_for_file($ign) . ' ' : '');
                printf $fh "t:search_once id:%s ac:%s %s%snick:%s topic:%s created_at:%s %s\n",
                  $t->{id}, $username, $ign, &get_reply_to($t), $t->{user}->{screen_name}, &encode_for_file($topic),
                  &encode_for_file($t->{created_at}), $text;
            }
        }
    }

    return 1;
}

sub get_timeline {
    my ( $fh, $target, $username, $obj, $cache, $is_update ) = @_;
    my $tweets;
    my $last_id = $state{__last_id}{$username}{__extras}{$target} if $is_update;

    &debug($fh, "%G$username%n get_timeline $target"
      . ($is_update ? "($fix_replies_index{$username} > $last_id)" : ''));
    my $arg_ref = { id => $target, };
    if ($is_update) {
        $arg_ref->{since_id} = $last_id if $last_id;
        $arg_ref->{include_rts} = 1 if $settings{retweet_show};
    } elsif ($settings{limit_user_tweets} and $settings{limit_user_tweets} =~ /\b(\d+)\b/) {
        $arg_ref->{count} = $1;
    }
    eval {
        $tweets = $obj->user_timeline($arg_ref);
    };

    if ($@) {
        print $fh "t:error $username user_timeline($target) call: Aborted.\n";
        print $fh "t:debug : $_\n" foreach split /\n/, Dumper($@);
        return;
    }

    unless ($tweets) {
        print $fh "t:error $username user_timeline($target) call returned undef!  Aborted\n";
        return 1;
    }

    my $not_before = time - $1*86400 if not $is_update and $settings{limit_user_tweets} and $settings{limit_user_tweets} =~ /\b(\d+)d\b/;
    foreach my $t ( reverse @$tweets ) {
        next if defined $not_before and &date_to_epoch($t->{created_at}) < $not_before;
        my $text = &get_text( $t, $obj );
        my $reply = &tweet_or_reply($obj, $t, $username, $cache, $fh);
        printf $fh "t:%s id:%s ac:%s %snick:%s created_at:%s %s\n",
          $reply, $t->{id}, $username, &get_reply_to($t), $t->{user}{screen_name},
          &encode_for_file($t->{created_at}), $text;
        $last_id = $t->{id} if $last_id < $t->{id};
        &get_unshorten_urls($text, $fh);
    }
    if ($is_update) {
        printf $fh "t:last_id_fixreplies id:%s ac:%s id_type:%s\n",
          $last_id, $username, $target;
    }

    return 1;
}

sub encode_for_file {
    my $datum = shift;
    $datum =~ s/\t/%09/g;
    $datum =~ s/ /%20/g;
    return $datum;
}

sub decode_from_file {
    my $datum = shift;
    $datum =~ s/%20/ /g;
    $datum =~ s/%09/\t/g;
    return $datum;
}

sub date_to_epoch {
    # parse created_at style date to epoch time
    my $date = shift;
    if (not @datetime_parser) {
        foreach my $date_fmt (
                        '%a %b %d %T %z %Y',	# Fri Nov 05 10:14:05 +0000 2010
                        '%a, %d %b %Y %T %z',	# Fri, 05 Nov 2010 16:59:40 +0000
                ) {
            my $parser = DateTime::Format::Strptime->new(pattern => $date_fmt);
            if (not defined $parser) {
                @datetime_parser = ();
                return;
            }
            push @datetime_parser, $parser;
        }
    }
    # my $orig_date = $date;
    $date = $datetime_parser[index($date, ',') == -1 ? 0 : 1]->parse_datetime($date);
    # &debug("date '$orig_date': " . ref($date));
    return if not defined $date;
    return $date->epoch();
}

sub meta_to_line {
    my $meta = shift;
    my %line_attribs = (
            username => $meta->{username}, epoch   => $meta->{created_at},
            type     => $meta->{type},     account => $meta->{account},
            service  => $meta->{service},  nick    => $meta->{nick},
            hilight  => 0,                 hi_nick => $meta->{nick},
            text     => $meta->{text},     topic   => $meta->{topic},
            level    => MSGLEVEL_PUBLIC,
    );

    if ($meta->{type} eq 'dm' or $meta->{type} eq 'error' or $meta->{type} eq 'deerror') {
        $line_attribs{level} = MSGLEVEL_MSGS;
    }

    my $nick = "\@$meta->{account}";
    if ( $meta->{text} =~ /\Q$nick\E(?:\W|$)/i ) {
        my $hilight_color        = $irssi_to_mirc_colors{ $settings{hilight_color} };
        $line_attribs{level}  |= MSGLEVEL_HILIGHT;
        $line_attribs{hi_nick} = "\cC$hilight_color$meta->{nick}\cO";
    }
    elsif ($settings{nick_color} eq 'rotate') {
        my $c = get_nick_color($meta->{nick});
        $line_attribs{hi_nick} = "\cC$c$meta->{nick}\cO";
    }

    if (defined $meta->{ign}) {
        $line_attribs{ignoring} = 1;
        $line_attribs{marker} = '-' . $meta->{ign};  # must have a marker for tweet theme

    } elsif ( $meta->{type} ne 'dm' and $meta->{nick} and $meta->{id} and not $meta->{ign} ) {
        ### not ignored, so we probably want it cached and create a :marker...
        my $marker;
        my $lc_nick = lc $meta->{nick};
        for (my $mark_idx = 0;
                defined $state{__ids}{ $lc_nick } and $mark_idx < @{ $state{__ids}{ $lc_nick } };
                $mark_idx++) {
            if ($state{__ids}{ $lc_nick }[$mark_idx] eq $meta->{id}) {
                $marker = $mark_idx;
                last;
            }
        }
        if (not defined $marker) {
            $marker = ( $state{__indexes}{ $lc_nick } + 1 ) % $settings{track_replies};
            $state{__ids}    { $lc_nick }[$marker] = $meta->{id};
            $state{__indexes}{ $lc_nick }          = $marker;
            $state{__tweets} { $lc_nick }[$marker] = $meta->{text};
            foreach my $key (qw/username reply_to_id reply_to_user created_at/) {
                # __usernames __reply_to_ids __reply_to_users __created_ats
                $state{"__${key}s"}{ $lc_nick }[$marker] = $meta->{$key} if defined $meta->{$key};
            }
        }
        $line_attribs{marker} = ":$marker";
    }
    return %line_attribs;
}

sub cache_to_meta {
    my $line = shift;
    my $type = shift;
    my %meta = ( type => $type );
    foreach my $key (@{ $_[0] }) {
        if ($line =~ s/^$key:(\S+)\s*//) {
            $key = 'account' if $key eq 'ac';
            $meta{$key} = $1;
            $meta{$key} = &decode_from_file($meta{$key});
            if ($key eq 'account') {
                $meta{username} = &normalize_username($meta{account});	# username is account@Service
                $meta{account} =~ s/\@(\w+)$//;
                $meta{service} = $1;
            } elsif ($key eq 'created_at') {
                $meta{created_at} = &date_to_epoch($meta{created_at});
            }
        }
    }
    $meta{text} = $line;
    return %meta;
}

sub monitor_child {
    my $args = shift;

    my $filename       = $args->[0];
    my $attempts_to_go = $args->[1];
    my $wait_time      = $args->[2];
    my $is_update      = $args->[3];
    my $filename_tmp   = $args->[4];
    my $prev_mtime     = $args->[5];

    my $file_progress = 'no ' . $filename_tmp;
    my $this_mtime = $prev_mtime;
    if (-f $filename_tmp) {
        $this_mtime = (stat(_))[9];
        $file_progress = 'mtime=' . $this_mtime;
    }
    &debug("checking child log at $filename [$file_progress v $prev_mtime] ($attempts_to_go)");

    # reap any random leftover processes - work around a bug in irssi on gentoo
    waitpid( -1, WNOHANG );

    # first time we run we don't want to print out *everything*, so we just
    # pretend

    my @lines = ();
    my %new_cache = ();
    my %types_per_user = ();
    my $got_errors = 0;
    my %show_now = ();       # for non-update info

    my $fh;
    if ( -e $filename and open $fh, '<', $filename ) {
        binmode $fh, ":" . &get_charset();
    } else {
        # file not ready yet

        if ( $attempts_to_go > 0 ) {
            Irssi::timeout_add_once( $wait_time, 'monitor_child',
                [ $filename, $attempts_to_go - 1, $wait_time, $is_update, $filename_tmp, $this_mtime ] );
        } else {
            &debug("Giving up on polling $filename");
            Irssi::pidwait_remove($child_pid);
            waitpid( -1, WNOHANG );
            unlink $filename unless &debug();

            if (not $is_update) {
                &notice([ 'error' ], "Failed to get response.  Giving up.");
                return;
            }

            $update_is_running = 0 if $is_update;

            return unless $settings{notify_timeouts};

            my $since;
            if ( time - $last_poll{__poll} < 24 * 60 * 60 ) {
                my @time = localtime($last_poll{__poll});
                $since = sprintf( "%d:%02d", @time[ 2, 1 ] );
            } else {
                $since = scalar localtime($last_poll{__poll});
            }

            if ( $failstatus < 2 and time - $last_poll{__poll} > 60 * 60 ) {
                &notice([ 'error' ],
                  $settings{mini_whale}
                  ? 'FAIL WHALE'
                  : q{     v  v        v},
                    q{     |  |  v     |  v},
                    q{     | .-, |     |  |},
                    q{  .--./ /  |  _.---.| },
                    q{   '-. (__..-"       \\},
                    q{      \\          a    |},
                    q{       ',.__.   ,__.-'/},
                    q{         '--/_.'----'`}
                );
                $failstatus = 2;
            }

            if ( $failstatus == 0 and time - $last_poll{__poll} < 600 ) {
                &notice([ 'error' ],"Haven't been able to get updated tweets since $since");
                $failstatus = 1;
            }
        }

        return;
    }

    # make sure we're not in slurp mode
    local $/ = "\n";
    while (<$fh>) {
        unless (/\n$/) {    # skip partial lines
            &debug($fh, "Skipping partial line: $_");
            next;
        }
        chomp;

        my $type;
        if (s/^t:(\w+)\s+//) {
            $type = $1;
        } else {
            &notice(['error'], "invalid: $_");
            next;
        }

        if ($type eq 'debug') {
            &debug($_);

        } elsif ($type =~ /^(error|info|deerror)$/) {
            $got_errors++ if $type eq 'error';
            &notice([$type], $_);

        } elsif ($type eq 'url') {
            my %meta = &cache_to_meta($_, $type, [ qw/epoch https site uri/ ]);
            $expanded_url{$meta{site}}{$meta{https} ? 1 : 0}{$meta{uri}} = {
                url => $meta{text},
                epoch => $meta{epoch},
            };

        } elsif ($type eq 'last_poll') {
            my %meta = &cache_to_meta($_, $type, [ qw/ac poll_type epoch/ ]);

            if ( not defined $meta{ac} and $meta{poll_type} eq '__poll' ) {
                $last_poll{$meta{poll_type}} = $meta{epoch};
            } elsif ( $meta{epoch} >= $last_poll{$meta{username}}{$meta{poll_type}} ) {
                $last_poll{$meta{username}}{$meta{poll_type}} = $meta{epoch};
                &debug("%G$meta{username}%n $meta{poll_type} updated to $meta{epoch}");
            } else {
               &debug("%G$meta{username}%n Impossible! $meta{poll_type}: "
                  . "new poll=$meta{epoch} < prev=$last_poll{$meta{username}}{$meta{poll_type}}!");
               $got_errors++;
            }

        } elsif ($type eq 'fix_replies_index') {
            my %meta = &cache_to_meta($_, $type, [ qw/idx ac topic id_type/ ]);
            $fix_replies_index{ $meta{username} } = $meta{idx};
            &debug("%G$meta{username}%n fix_replies_index set to $meta{idx}");

        } elsif ($type eq 'searchid' or $type eq 'last_id_fixreplies' or $type eq 'last_id') {
            my %meta = &cache_to_meta($_, $type, [ qw/id ac topic id_type/ ]);
            if ( $meta{type} eq 'searchid' ) {
                &debug("%G$meta{username}%n Search '$meta{topic}' got id $meta{id}");
                if (not exists $state{__last_id}{ $meta{username} }{__search}{ $meta{topic} }
                        or $meta{id} >= $state{__last_id}{ $meta{username} }{__search}{ $meta{topic} } ) {
                    $state{__last_id}{ $meta{username} }{__search}{ $meta{topic} } = $meta{id};
                } else {
                    &debug("%G$meta{username}%n Search '$meta{topic}' bad id $meta{id}");
                    $got_errors++;
                }
            } elsif ( $meta{type} eq 'last_id') {
                $state{__last_id}{ $meta{username} }{ $meta{id_type} } = $meta{id}
                  if $state{__last_id}{ $meta{username} }{ $meta{id_type} } < $meta{id};
            } elsif ( $meta{type} eq 'last_id_fixreplies' ) {
                $state{__last_id}{ $meta{username} }{__extras}{ $meta{id_type} } = $meta{id}
                  if $state{__last_id}{ $meta{username} }{__extras}{ $meta{id_type} } < $meta{id};
            }

        } elsif ($type eq 'tweet' or $type eq 'dm' or $type eq 'reply' or $type eq 'search' or $type eq 'search_once') {	# cf theme_register
            my %meta = &cache_to_meta($_, $type, [ qw/id ac ign reply_to_user reply_to_id nick topic created_at/ ]);

            if (exists $new_cache{ $meta{id} }) {
                &debug("SKIP newly-cached $meta{id}");
                next;
            }
            $new_cache{ $meta{id} } = time;
            if (exists $tweet_cache{ $meta{id} }) {
                       # and (not $retweeted_id{$username} or not $retweeted_id{$username}{ $meta{id} });
                &debug("SKIP cached $meta{id}");
                next;
            }

            my %line_attribs = &meta_to_line(\%meta);
            push @lines, { %line_attribs };

            if ( $meta{type} eq 'search' ) {
                if ( exists $state{__last_id}{ $meta{username} }{__search}{ $meta{topic} }
                        and $meta{id} > $state{__last_id}{ $meta{username} }{__search}{ $meta{topic} } ) {
                    $state{__last_id}{ $meta{username} }{__search}{ $meta{topic} } = $meta{id};
                }
            } elsif ( $meta{type} eq 'search_once' ) {
                delete $search_once{ $meta{username} }->{ $meta{topic} };
            }

        } elsif ($type eq 'friend' or $type eq 'block' or $type eq 'list') {
            my %meta = &cache_to_meta($_, $type, [ qw/ac list id nick epoch/ ]);
            if ($is_update and not defined $types_per_user{$meta{username}}{$meta{type}}) {
                if ($meta{type} eq 'friend') {
                    $friends{$meta{username}} = ();
                } elsif ($meta{type} eq 'block') {
                    $blocks{$meta{username}} = ();
                } elsif ($meta{type} eq 'list') {
                    my ($list_account, $list_name) = split '/', $meta{list};
                    $state{__lists}{$list_account} = {};
                }
                $types_per_user{$meta{username}}{$meta{type}} = 1;
            }
            if ($meta{type} eq 'friend') {
                $nicks{$meta{nick}} = $friends{$meta{username}}{$meta{nick}} = $meta{epoch};
            } elsif ($meta{type} eq 'block') {
                $blocks{$meta{username}}{$meta{nick}} = $meta{epoch};
            } elsif ($meta{type} eq 'list') {
                my ($list_account, $list_name) = split '/', $meta{list};
                if (not exists $state{__lists}{$list_account}{$list_name}) {
                    $state{__lists}{$list_account}{$list_name} = { id=>$meta{id}, members=>[] };
                }
                $show_now{lists}{$list_account}{$list_name} = $meta{id} if not $is_update;
                push @{ $state{__lists}{$list_account}{$list_name}{members} }, $meta{nick};
            }

        } else {
            &notice(['error'], "invalid type ($type): $_");
        }
    }

    # file was opened, so we tried to parse...
    close $fh;

    # make sure the pid is removed from the waitpid list
    Irssi::pidwait_remove($child_pid);

    # and that we don't leave any zombies behind, somehow
    waitpid( -1, WNOHANG );

    &debug("new last_poll    = $last_poll{__poll}",
           "new last_poll_id = " . Dumper( $state{__last_id} )) if $is_update;
    if ($is_update and $first_call and not $settings{force_first}) {
        &debug("First call, not printing updates");
    } else {

        if (exists $show_now{lists}) {
            for my $list_account (keys %{ $show_now{lists} }) {
                my $list_ac = ($list_account eq "$user\@$defservice" ? '' : "$list_account/");
                for my $list_name (keys %{ $show_now{lists}{$list_account} }) {
                    if (0 == @{ $state{__lists}{$list_account}{$list_name}{members} }) {
                        &notice(['info'], "List $list_ac$list_name is empty.");
                    } else {
                        &notice("List $list_ac$list_name members: " .
                                join(', ', @{ $state{__lists}{$list_account}{$list_name}{members} }));
                    }
                }
            }
        }

        &write_lines(\@lines, $is_update);
    }

    unlink $filename or warn "Failed to remove $filename: $!" unless &debug();

    # commit the pending cache lines to the actual cache, now that
    # we've printed our output
    for my $updated_id (keys %new_cache) {
        $tweet_cache{$updated_id} = $new_cache{$updated_id};
    }

    # keep enough cached tweets, to make sure we don't show duplicates
    for my $loop_id ( keys %tweet_cache ) {
        next if $tweet_cache{$loop_id} >= $last_poll{__poll} - 3600;
        delete $tweet_cache{$loop_id};
    }

    if (not $got_errors) {
        &save_state();
    }

    if ($is_update) {
        if ($failstatus and not $got_errors) {
            &notice([ 'deerror' ], "Update succeeded.");
            $failstatus    = 0;
        }
        $first_call        = 0;
        $update_is_running = 0;
    }
}

sub write_lines {
    my $lines_ref       = shift;
    my $is_update       = shift;
    my $ymd_color = $irssi_to_mirc_colors{ $settings{ymd_color} };
    my @date_now = localtime();
    my $ymd_now = sprintf('%04d-%02d-%02d', $date_now[5]+1900, $date_now[4]+1, $date_now[3]);
    my $old_tf;
    #	&debug("line: " . Dumper $lines_ref);
    foreach my $line (@$lines_ref) {
        my $line_want_extras = $is_update;
        my $win_name = &window( $line->{type}, $line->{username}, $line->{nick}, $line->{topic} );
        my $ac_tag = '';
        if ( lc $line->{service} ne lc $settings{default_service} ) {
            $ac_tag = "$line->{username}: ";
        } elsif ( $line->{username} ne "$user\@$defservice"
                and lc $line->{account} ne lc $win_name ) {
            $ac_tag = $line->{account} . ': ';
        }

        my @print_opts = (
            $line->{level},
            "twirssi_" . $line->{type},   # theme
            $ac_tag,
        );
        push @print_opts, (lc $line->{topic} ne lc $win_name ? $line->{topic} . ':' : '')
          if $line->{type} =~ /search/;
        push @print_opts, $line->{hi_nick} if $line->{type} ne 'error' and $line->{type} ne 'deerror';
        push @print_opts, $line->{marker} if defined $line->{marker};

        # set timestamp
        my @date = localtime($line->{epoch});
        my $ymd  = sprintf('%04d-%02d-%02d', $date[5]+1900, $date[4]+1, $date[3]);
        my $ymd_suffix = '';
        if (defined $line->{ignoring}) {
            next if not $settings{debug};
            $line->{text} = "\cC$irssi_to_mirc_colors{'%b'}IGNORED\cO " . $line->{text};
            if ($settings{debug_win_name} ne '' ) {
                $win_name = $settings{debug_win_name};
            } else {
                $win_name = '(status)';
                $line->{text} = "%g[$IRSSI{name}] %n " . $line->{text};
            }
            $line_want_extras = 0;
        } elsif (not $is_update) {
            $ymd_suffix = " \cC$ymd_color$ymd\cO" if $ymd_now ne $ymd;
        } elsif (not defined $last_ymd{wins}{$win_name}
                  or $last_ymd{wins}{$win_name}->{ymd} ne $ymd) {
            Irssi::window_find_name($win_name)->printformat(MSGLEVEL_PUBLIC, 'twirssi_new_day', $ymd, '');
            $last_ymd{wins}{$win_name}->{ymd} = $ymd;
        }
        my $ts = DateTime->from_epoch( epoch => $line->{epoch}, time_zone => $local_tz
                                                    )->strftime($settings{timestamp_format});
        if (not defined $old_tf) {
            $old_tf = Irssi::settings_get_str('timestamp_format');
        }
        $line->{text} = &post_process_tweet($line->{text});
        Irssi::command("^set timestamp_format $ts");
        Irssi::window_find_name($win_name)->printformat(
            @print_opts, &hilight( $line->{text} ) . $ymd_suffix
        );
        if ($line_want_extras) {
            &write_log($line, $win_name, \@date);
            &write_channels($line, \@date);
        }
    }
    # recall timestamp format
    if (defined $old_tf) {
        Irssi::command("^set timestamp_format $old_tf");
        &debug((0+@$lines_ref) . " lines, pre-ts: " . $old_tf);
    }
}

sub write_channels {
    my $line = shift;
    my $date_ref = shift;
    my %msg_seen;
    for my $type ($line->{type}, 'sender', '*') {
        next unless defined $state{__channels}{$type};
        for my $tag (($type eq 'sender' ? $line->{nick}
                                        : ($line->{type} =~ /search/ ? $line->{topic}
                                                                     : $line->{username})),
                          '*') {
            next unless defined $state{__channels}{$type}{$tag};
            for my $net_tag (keys %{ $state{__channels}{$type}{$tag} }) {
                for my $channame (@{ $state{__channels}{$type}{$tag}{$net_tag} }) {
                    next if defined $msg_seen{$net_tag}{$channame};
                    my $server = Irssi::server_find_tag($net_tag);
                    $last_ymd{chans}{$channame} = {} if not defined $last_ymd{chans}{$channame};
                    for my $log_line (&log_format($line, $channame, $last_ymd{chans}{$channame}, $date_ref)) {
                        if (defined $server) {
                            $server->command("msg -$net_tag $channame $log_line");
                            $msg_seen{$net_tag}{$channame} = 1;
                        } else {
                            &notice("no server for $net_tag/$channame: $log_line");
                        }
                    }
                }
            }
        }
    }
}

sub write_log {
    my $line = shift;
    my $win_name = shift;
    my $date_ref = shift;
    return unless my $logfile_obj = &ensure_logfile($win_name);
    my $fh = $logfile_obj->{fh};
    for my $log_line (&log_format($line, $logfile_obj->{filename}, $logfile_obj, $date_ref, 1)) {
        print $fh $log_line, "\n";
    }
}

sub log_format {
    my $line = shift;
    my $target_name = shift;
    my $ymd_obj = shift;        # can be $last_ymd{chans}{$chan} or $logfile_obj (both need to have ->{ymd})
    my $date_ref = shift;
    my $to_file = shift;

    my @logs = ();

    my $ymd = sprintf('%04d-%02d-%02d', $date_ref->[5]+1900, $date_ref->[4]+1, $date_ref->[3]);
    if ($ymd_obj->{ymd} ne $ymd) {
        push @logs, "Day changed to $ymd" if $ymd ne '';
        $ymd_obj->{ymd} = $ymd;
    }

    my $out = '';
    $out .= sprintf('%02d:%02d:%02d ', $date_ref->[2], $date_ref->[1], $date_ref->[0]) if $to_file;
    if ( $line->{type} eq 'dm' ) {
        $out .= 'DM @' . $line->{hi_nick} . ':';
    } elsif ( $line->{type} eq 'search' or $line->{type} eq 'search_once' ) {
        $out .= '[' . ($target_name =~ /$line->{topic}/ ? '' : "$line->{topic}:")
                . '@' . $line->{hi_nick} . ']';
    } elsif ( $line->{type} eq 'tweet' or $line->{type} eq 'reply' ) {
        $out .= '<' . ($target_name =~ /$line->{account}/ ? '' : "$line->{account}:")
                . '@' . $line->{hi_nick} . '>';
    } else {
        $out .= 'ERR:';
    }
    push @logs, $out . ' ' . ($to_file ? &remove_colors($line->{text}) : $line->{text});
    return @logs;
}

sub remove_colors {
    my $txt = shift;
    $txt =~ s/\cC\d{2}(.*?)\cO/$1/g;
    return $txt;
}

sub save_state {
    # save state hash
    if ( keys %state and my $file = $settings{replies_store} ) {
        if ( open my $fh, '>', $file ) {
            print $fh JSON::Any->objToJson( \%state );
            close $fh;
        } else {
            &notice([ 'error' ],"Failed to write state to $file: $!");
        }
    }
    # save id hash
    if ( my $file = $settings{id_store} ) {
        if ( open my $fh, '>', $file ) {
            print $fh JSON::Any->objToJson( \%tweet_cache );
            close $fh;
        } else {
            &notice([ 'error' ],"Failed to write IDs to $file: $!");
        }
    }
}

sub save_polls {
    # save last_poll hash
    if ( keys %last_poll and my $file = $settings{poll_store} ) {
        if ( open my $fh, '>', $file ) {
            print $fh JSON::Any->objToJson( \%last_poll );
            close $fh;
        } else {
            &notice([ 'error' ], "Failed to write polls to $file: $!");
        }
    }
}

sub debug {
    return if not $settings{debug};
    my $fh;
    $fh = shift if ref($_[0]) eq 'GLOB';
    while (@_) {
        my $line = shift;
        next if not defined $line;
        chomp $line;
        for my $sub_line (split("\n", $line)) {
            next if $sub_line eq '';
            if ($fh) {
                print $fh 't:debug +', substr(time, -3), ' ', $sub_line, "\n";
            } elsif ($settings{debug_win_name} ne '') {
                my $dbg_win = $settings{debug_win_name};
                $dbg_win = $settings{window} if not &ensure_window($dbg_win);
                Irssi::window_find_name($dbg_win)->print(
                    $sub_line, MSGLEVEL_PUBLIC );
            } else {
                print "[$IRSSI{name}] ", $sub_line;
            }
        }
    }
    return 1;
}

sub notice {
    my ( $type, $tag, $fh, $theme );
    if ( ref $_[0] ) {
        ( $type, $tag, $fh ) = @{ shift @_ };
        $theme = 'twirssi_' . $type;
    }
    foreach my $msg (@_) {
        if (defined $fh) {
            for my $sub_line (split("\n", $msg)) {
                print $fh "t:$type ", $sub_line, "\n" if $sub_line ne '';
            }
        } else {
            my $col = '%G';
            my $win_level = MSGLEVEL_PUBLIC;
            my $win;
            if ($tag eq '_tw_in_Win') {
                $win = Irssi::active_win();
            } elsif ($type eq 'crap') {
                $win = Irssi::window_find_name(&window());
                $col = '%R';
                $win_level = MSGLEVEL_CLIENTCRAP;
            } else {
                $win = Irssi::window_find_name(&window( $type, $tag ));
            }

            if ($type =~ /^(error|info|deerror)$/) {
                $win->printformat(MSGLEVEL_PUBLIC, $theme, $msg); # theme
            } else {
                $win->print("${col}***%n $msg", $win_level );
            }
        }
    }
}

sub update_away {
    my $data = shift;

    if ( $data !~ /\@\w/ and $data !~ /^[dD] / ) {
        my $server = Irssi::server_find_tag( $settings{bitlbee_server} );
        if ($server) {
            $server->send_raw("away :$data");
            return 1;
        } else {
            &notice([ 'error' ], "Can't find bitlbee server.",
                "Update bitlbee_server or disable tweet_to_away" );
            return 0;
        }
    }

    return 0;
}

sub too_long {
    my $data     = shift;
    my $alert_to = shift;

    if ( length $data > 140 ) {
        &notice( $alert_to,
            "Tweet too long (" . length($data) . " characters) - aborted" )
          if defined $alert_to;
        return 1;
    }

    return 0;
}

sub make_utf8 {
    my $data = shift;
    if ( !utf8::is_utf8($data) ) {
        return decode &get_charset(), $data;
    } else {
        return $data;
    }
}

sub valid_username {
    my $username = shift;

    $username = &normalize_username($username);

    unless ( exists $twits{$username} ) {
        &notice( ["error", $username], "Unknown username $username" );
        return;
    }

    return $username;
}

sub logged_in {
    my $obj = shift;
    unless ($obj) {
        &notice( ["error"],
            "Not logged in!  Use /twitter_login username" );
        return 0;
    }

    return 1;
}

sub sig_complete {
    my ( $complist, $window, $word, $linestart, $want_space ) = @_;

    my $cmdchars = quotemeta Irssi::settings_get_str('cmdchars');
    my $comp_type = '';
    my $keep_at = 0;
    my $lc_stag = '';

    my $cmd = '';
    my @args = ();
    my $want_account = 0;
    if ($linestart =~ m@^ [$cmdchars] (\S+?)(_as)? ((?: \s+ \S+ )*) \s* $@xi) {
        $cmd = lc $1;
        my $cmd_as = $2;
        my $args = $3;
        $args =~ s/^\s+//;
        @args = split(/\s+/, $args);
        if ($cmd_as) {
            if (@args) {
                # act as if "_as ac" is not there
                shift @args;
            } elsif ($cmd =~ /^(?:twitter|twirssi|tweet|dm|retweet)/) {
                $want_account = 1;
            }
        }
    }

    if (not @args) {
        if ($want_account or grep { $cmd eq $_ } @{ $completion_types{'account'} }) {
            # '*_as' and 'account' types expect account as first arg
            $word =~ s/^@//;
            @$complist = grep /^\Q$word/i, map { s/\@.*// and $_ } keys %twits;
            return;
        }
        if (grep { $cmd eq $_ } @{ $completion_types{'tweet'} }) {
            # 'tweet' expects nick:num (we offer last num for each nick)
            $word =~ s/^@//;
            @$complist = map { "$_:$state{__indexes}{lc $_}" }
              sort { $nicks{$b} <=> $nicks{$a} }
                grep /^\Q$word/i, keys %{ $state{__indexes} };
            return;
        }
        if (grep { $cmd eq $_ } @{ $completion_types{'nick'} }) {
            # 'nick' expects a nick
            $comp_type = 'nick';
        }
    }

    # retweet_to non-first args
    if ($cmd eq 'retweet_to') {
        if (@args == 1) {
            @$complist = grep /^\Q$word/i, map { "-$_->{tag}" } Irssi::servers();
            return;
        } elsif (@args == 2) {
            @$complist = grep /^\Q$word/i, qw/ -channel -nick /;
            return;
        } elsif (@args == 3 and $args[2] =~ m{^ -(channel|nick) $}x) {
            $lc_stag = lc $args[1];
            $lc_stag = substr($lc_stag, 1) if substr($lc_stag, 0, 1) eq '-';
            $comp_type = $1;
        }
    }

    # twirssi_set_window twirssi_set_channel
    if ($cmd eq 'twirssi_set_window' or $cmd eq 'twirssi_set_channel') {
        my $set_type = substr($cmd, 12);
        if (@args == 0) {
            @$complist = grep /^\Q$word/i, @{ $valid_types{$set_type} };
            return;
        } elsif (@args == 1) {
            $comp_type = 'nick';
        } elsif (@args == 2) {
            if ($set_type eq 'window') {
                @$complist = map { $_->{name} || $_->{active}->{name} }
                             grep { my $n = $_->{name} || $_->{active}->{name}; $n =~ /^\Q$word\E/i } Irssi::windows();
                return;
            } elsif ($set_type eq 'channel') {
                $comp_type = $set_type;
            }
        }
    }

    # anywhere in line...
    if (not $comp_type and grep { $cmd eq $_ } @{ $completion_types{'re_nick'} }) {
        # 're_nick' can have @nick anywhere
        $comp_type = 'nick';
        $keep_at = 1;
    }

    if ($comp_type eq 'channel') {
        @$complist = map { $_->{name} }
                       grep { $_->{name} =~ /^\Q$word\E/i and ($lc_stag eq '' or lc($_->{server}->{tag}) eq $lc_stag) }
                         Irssi::channels();
        return;
    } elsif ($comp_type eq 'nick') {
        my $prefix = $1 if $word =~ s/^(@)//;
        @$complist = map { ($prefix and $keep_at) ? "$prefix$_" : $_ }
                       grep /^\Q$word/i, sort { $nicks{$b} <=> $nicks{$a} } keys %nicks;
        return;
    }
}

sub event_send_text {
    my ( $line, $server, $win ) = @_;
    my $awin = Irssi::active_win();

    # if the window where we got our text was the twitter window, and the user
    # wants to be lazy, tweet away!
    my $acc = &window_to_account( $awin->get_active_name() );
    if ( $acc and $settings{window_input} ) {
        &cmd_tweet_as( "$acc $line", $server, $win );
    }
}

sub event_setup_changed {
    my $do_add = shift;	# first run, want to add, too
    my @changed_stgs = ();

    foreach my $setting (@settings_defn) {
        my $setting_changed = 0;
        my $stg_type .= '_' . ($setting->[2] eq 'b' ? 'bool'
                                        : $setting->[2] eq 'i' ? 'int'
                                                : $setting->[2] eq 's' ? 'str' : '');
        if ($stg_type eq '_') {
            if ($do_add) {
                print        "ERROR: Bad opt '$setting->[2]' for $setting->[0]";
            } else {
                &notice( ["error"], "Bad opt '$setting->[2]' for $setting->[0]" );
            }
            next;
        }

        my $stg_type_fn;
        if ($do_add) {
            $stg_type_fn = 'Irssi::settings_add' . $stg_type;	# settings_add_str, settings_add_int, settings_add_bool
            no strict 'refs';
            $settings{ $setting->[0] } = &$stg_type_fn( $IRSSI{name}, $setting->[1], $setting->[3] );
        }

        my $prev_stg;
        {
            $prev_stg = $settings{ $setting->[0] };
            $stg_type_fn = 'Irssi::settings_get' . $stg_type;	# settings_get_str, settings_get_int, settings_get_bool
            no strict 'refs';
            $settings{ $setting->[0] } = &$stg_type_fn( $setting->[1] );
        }
        if ($setting->[2] eq 's') {
            my $pre_proc = $setting->[4];
            my $trim = 1;
            my $norm_user = 0;
            my $is_list = 0;
            while (defined $pre_proc and $pre_proc ne '') {
                if ($pre_proc =~ s/^lc(?:,|$)//) {
                    $settings{$setting->[0]} = lc $settings{$setting->[0]};
                } elsif ($pre_proc =~ s/^list{(.)}(?:,|$)//) {
                    my $re = $1;
                    $re = qr/\s*$re\s*/ if $trim;
                    if ($settings{$setting->[0]} eq '') {
                        $settings{$setting->[0]} = [ ];
                    } else {
                        $settings{$setting->[0]} = [ split($re, $settings{$setting->[0]}) ];
                        if (grep { $_ eq $setting->[0] } ('passwords')) {
                            # ends '\', unescape separator:  concatenate with next
                            for (my $i = 0;  $i+1 < @{ $settings{$setting->[0]} };  $i++) {
                                while ( $settings{$setting->[0]}->[$i] =~ /\\$/ ) {
                                    $settings{$setting->[0]}->[$i] .= "," . delete $settings{$setting->[0]}->[$i+1];
                                }
                            }
                        }
                    }
                    $is_list = 1;
                } elsif ($pre_proc =~ s/^norm_user(?:,|$)//) {
                    $norm_user = 1;
                } elsif ($do_add) {
                    print        "ERROR: Bad opt pre-proc '$pre_proc' for $setting->[0]";
                } else {
                    &notice( ["error"], "Bad opt pre-proc '$pre_proc' for $setting->[0]" );
                }
                if ($norm_user) {
                    my @normed = ();
                    for my $to_norm ($is_list ? @{ $settings{$setting->[0]} } : $settings{$setting->[0]} ) {
                        next if $to_norm eq '';
                        &debug($setting->[0] . ' to_norm {' . $to_norm . '}');
                        push @normed, &normalize_username($to_norm, 1);
                    }
                    $is_list = 1;
                    $settings{$setting->[0]} = ($is_list ? \@normed : $normed[0]);
                }
            }
            if (Dumper($prev_stg) ne Dumper($settings{ $setting->[0] })) {
                $setting_changed = 1;
            }
        } elsif ($prev_stg != $settings{ $setting->[0] }) {
            $setting_changed = 1;
        }
        push @changed_stgs, $setting->[0] if $setting_changed and not $do_add;
        if ($setting_changed or $do_add) {
            if ($setting->[0] eq 'poll_interval'
                    or $setting->[0] eq 'poll_schedule' ) {
                &ensure_updates();
            }
        }
    }
    &debug('changed settings: ' . join(', ', @changed_stgs)) if @changed_stgs;

    &ensure_logfile($settings{window});

    if ($do_add or grep 'url_unshorten', @changed_stgs) {
        # want to load this in the parent to allow child to use it expediently
        &load_ua();
    }
    &debug("Settings changed ($do_add):" . Dumper \%settings);
}

sub ensure_logfile() {
    my $win_name = shift;
    return unless $settings{logging};
    my $new_logfile = Irssi::settings_get_str('autolog_path');
    return if $new_logfile eq '';
    $new_logfile =~ s/^~/$ENV{HOME}/;
    $new_logfile = strftime($new_logfile, localtime());
    $new_logfile =~ s/\$(tag\b|\{tag\})/$IRSSI{name}/g;
    if ($new_logfile !~ s/\$(0\b|\{0\})/$win_name/g) {
        # not per-window logging, so use default window name as key
        $win_name = $settings{window};
    }
    return $logfile{$win_name} if defined $logfile{$win_name} and $new_logfile eq $logfile{$win_name}->{filename};
    return if not &ensure_dir_for($new_logfile);
    my $old_umask = umask(0177);
    &debug("Logging to $new_logfile");
    my $res;
    if ( my $fh = FileHandle->new( $new_logfile, '>>' ) ) {
        umask($old_umask);
        binmode $fh, ':utf8';
        $fh->autoflush(1);
        $res = $logfile{$win_name} = {
                'fh' => $fh,
                'filename' => $new_logfile,
                'ymd' => '',
        };
    } else {
        &notice( ["error"], "Failed to append to $new_logfile: $!" );
    }
    umask($old_umask);
    return $res;
}

sub ensure_dir_for {
    my $path = shift;
    if (not $path =~ s@/[^/]+$@@) {
        &debug("Cannot cd up $path");
        return;
    }
    return 1 if $path eq '' or -d $path or $path eq '/';
    return if not &ensure_dir_for($path);
    if (not mkdir($path, 0700)) {
        &debug("Cannot make $path: $!");
        return;
    }
    return 1;
}

sub get_poll_time {
    my $poll = $settings{poll_interval};

    my $hhmm;
    foreach my $tuple ( @{ $settings{poll_schedule} } ) {
        if ( $tuple =~ /^(\d{4})-(\d{4}):(\d+)$/ ) {
            $hhmm = sprintf('%02d%02d', (localtime())[2,1]) if not defined $hhmm;
            my($range_from, $range_to, $poll_val) = ($1, $2, $3);
            if ( ( $hhmm ge $range_from and $hhmm lt $range_to )
                or ( $range_from gt $range_to
                    and ( $hhmm ge $range_from or $hhmm lt $range_to ) )
               ) {
                $poll = $poll_val;
            }
        }
    }
    return $poll if $poll >= 60;
    return 60;
}

sub get_charset {
    my $charset = $settings{charset};
    return "utf8" if $charset =~ /^\s*$/;
    return $charset;
}

my @available_nick_colors =(
    0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
    '0,2', '0,3', '0,5', '0,6',
    '1,0', '1,3', '1,5', '1,6', '1,7', '1,10', '1,15',
    '2,3', '2,7', '2,10', '2,15',
    '3,2', '3,5', '3,10',
    '4,2', '4,7',
    '5,2', '5,3', '5,7', '5,10', '5,15',
    '6,2', '6,7', '6,10', '6,15',
    '8,2', '8,5', '8,6',
    '9,2', '9,5', '9,6',
    '10,2', '10,5', '10,6',
    '11,2', '11,5', '11,6',
    '12,2', '12,5',
    '13,2', '13,15',
    '14,2', '14,5', '14,6',
    '15,2', '15,5', '15,6'
);
my %nick_colors;

sub get_nick_color {
    if ($settings{nick_color} eq 'rotate') {
        my $nick = shift;

        if (!defined $nick_colors{$nick}) {
            my @chars = split //, lc $nick;
            my $value = 0;
            foreach my $char (@chars) {
                $value += ord $char;
            }
            $nick_colors{$nick} = $available_nick_colors[$value % @available_nick_colors];
        }
        return $nick_colors{$nick};
    } else {
        return $irssi_to_mirc_colors{$settings{nick_color}};
    }
}

sub hilight {
    my $text = shift;

    if ( $settings{nick_color} ) {
        $text =~ s[(^|\W)\@(\w+)] {
            my $c = get_nick_color($2);
            qq[$1\cC$c\@$2\cO];
        }eg;
    }
    if ( $settings{topic_color} ) {
        my $c = $settings{topic_color};
        $c = $irssi_to_mirc_colors{$c};
        $text =~ s/(^|\W)(\#|\!)([-\w]+)/$1\cC$c$2$3\cO/g if $c;
    }
    $text =~ s/[\n\r]/ /g;

    return $text;
}

sub shorten {
    my $data = shift;

    my $provider = $settings{url_provider};
    if ( ( $settings{always_shorten} or &too_long($data) ) and $provider ) {
        my @args;
        if ( $provider eq 'Bitly' ) {
            @args[ 1, 2 ] = split ',', $settings{url_args}, 2;
            unless ( @args == 3 ) {
                &notice([ 'crap' ],
                    "WWW::Shorten::Bitly requires a username and API key.",
                    "Set short_url_args to username,API_key or change your",
                    "short_url_provider."
                );
                return &make_utf8($data);
            }
        }

        foreach my $url ( $data =~ /(https?:\/\/\S+[\w\/])/g ) {
            eval {
                $args[0] = $url;
                my $short = makeashorterlink(@args);
                if ($short) {
                    $data =~ s/\Q$url/$short/g;
                } else {
                    &notice( ["error"], "Failed to shorten $url!" );
                }
            };
        }
    }

    return &make_utf8($data);
}


sub load_ua {
    return if defined $ua or not @{ $settings{url_unshorten} };
    &notice("Loading LWP and ua...");
    eval "use LWP;";
    $ua = LWP::UserAgent->new(
        env_proxy => 1,
        timeout => 10,
        agent => "$IRSSI{name}/$VERSION",
        requests_redirectable => [],
    );
}


sub is_url_from_shortener {
    my $url = shift;
    return unless @{ $settings{url_unshorten} }
           and $url =~ s@^https?://([\w.]+)/.*@lc $1@e;
    return grep { $url eq $_ } @{ $settings{url_unshorten} };
}


sub get_url_parts {
    my $url = shift;
    my @parts = ($url =~ m@^(https?)://([^/]+)/(.+)@i);
    $parts[0] = lc $parts[0];
    $parts[1] = lc $parts[1];
    return @parts;
}


sub get_unshorten_urls {
    my $text = shift;
    my $fh   = shift;
    return unless @{ $settings{url_unshorten} };
    foreach my $url ( $text =~ m@\b(https?://\S+[\w/])@g ) {
        my @orig_url_parts;
        my @url_parts;
        my $new_url = $url;
        my $max_redir = 4;
        my $resp;
        while ($max_redir-- > 0
                and @url_parts = &get_url_parts($new_url)
                and grep { $url_parts[1] eq $_ } @{ $settings{url_unshorten} }
                and not defined $expanded_url{$url_parts[1]}{$url_parts[0] eq 'https' ? 1 : 0}{$url_parts[2]}
                and $resp = $ua->head($new_url)
                and (defined $resp->header('Location')
                     or (&debug($fh, "cut_short $new_url => " . $resp->header('Host')) and 0)
                    )) {
            &debug($fh, "deshort $new_url => " . $resp->header('Location'));
            @orig_url_parts = @url_parts if not @orig_url_parts;
            $new_url = $resp->header('Location');
        }
        if (@orig_url_parts) {
            $expanded_url{$orig_url_parts[1]}{$orig_url_parts[0] eq 'https' ? 1 : 0}{$orig_url_parts[2]} = {
                url => $new_url,
                epoch => time,
            };
        }
    }
}


sub put_unshorten_urls {
    my $fh    = shift;
    my $epoch = shift;
    for my $site (keys %expanded_url) {
        for my $https (keys %{ $expanded_url{$site} }) {
            for my $uri (keys %{ $expanded_url{$site}{$https} }) {
                next if $expanded_url{$site}{$https}{$uri}{epoch} < $epoch;
                print $fh "t:url epoch:$expanded_url{$site}{$https}{$uri}{epoch} ",
                      ($https ? 'https:1 ' : ''),
                      "site:$site uri:$uri $expanded_url{$site}{$https}{$uri}{url}\n";
            }
        }
    }
}


sub post_process_tweet {
    my $data = shift;
    my $skip_unshorten = shift;
    if (@{ $settings{url_unshorten} } and not $skip_unshorten) {
        for my $site (keys %expanded_url) {
            for my $https (keys %{ $expanded_url{$site} }) {
                my $url = ($https ? 'https' : 'http') . '://' . $site . '/';
                next if -1 == index($data, $url);
                for my $uri (keys %{ $expanded_url{$site}{$https} }) {
                    $data =~ s/\Q$url$uri\E/$& \cC$irssi_to_mirc_colors{$settings{unshorten_color}}<$expanded_url{$site}{$https}{$uri}{url}>\cO/g;
                }
            }
        }
    }
    return &make_utf8($data);
}


sub normalize_username {
    my $user      = shift;
    my $non_login = shift;
    return '' if $user eq '';

    my ( $username, $service ) = split /\@/, lc($user), 2;
    if ($service) {
        $service = ucfirst $service;
    } else {
        $service = ucfirst lc $settings{default_service};
        unless ( $non_login or exists $twits{"$username\@$service"} ) {
            $service = undef;
            foreach my $t ( sort keys %twits ) {
                next unless $t =~ /^\Q$username\E\@(Twitter|Identica)/;
                $service = $1;
                last;
            }

            unless ($service) {
                &notice( ["error"], "Can't find a logged in user '$user'" );
                return "$username\@$settings{default_service}";
            }
        }
    }

    return "$username\@$service";
}

sub get_text {
    my $tweet  = shift;
    my $object = shift;
    my $text   = decode_entities( $tweet->{text} );
    if ( exists $tweet->{retweeted_status} ) {
        $text = &format_expand(fmt => $settings{retweeted_format} || $settings{retweet_format},
                  nick => $tweet->{retweeted_status}{user}{screen_name}, data => '',
                  tweet => decode_entities( $tweet->{retweeted_status}{text} ));
    } elsif ( $tweet->{truncated} and $object->isa('Net::Twitter') ) {
        $text .= " -- http://twitter.com/$tweet->{user}{screen_name}"
          . "/status/$tweet->{id}";
    }

    $text =~ s/[\n\r]/ /g;

    return $text;
}

sub window {
    my $type  = shift || "default";
    my $uname = shift || "default";
    my $sname = lc(shift);
    my $topic = lc(shift || '');

    $type = "search" if $type eq 'search_once';
    $type = "error" if $type eq 'deerror';

    my $win;
    my @all_priorities = qw/ account sender list /;
    my @win_priorities = split ',', $settings{window_priority};
    my $done_rest = 0;
    while (@win_priorities and not defined $win) {
        my $win_priority = shift @win_priorities;
        if ($win_priority eq 'account') {
            for my $type_iter ($type, 'default') {
                next unless exists $state{__windows}{$type_iter};
                $win =
                     $state{__windows}{$type_iter}{$uname}
                  || $state{__windows}{$type_iter}{$topic}
                  || $state{__windows}{$type_iter}{$user}
                  || $state{__windows}{$type_iter}{default};
                last if defined $win or $type_iter eq 'default';
            }
        } elsif ($win_priority eq 'sender') {
            if (defined $sname
                    and defined $state{__windows}{$win_priority}{$sname}) {
                $win = $state{__windows}{$win_priority}{$sname};
            }
        } elsif ($win_priority eq 'list') {
            if (defined $sname
                    and defined $state{__windows}{$win_priority}{$sname}) {
                $win = $state{__windows}{$win_priority}{$sname};
            }
        }
        if (not defined $win and not @win_priorities and not $done_rest) {
            $done_rest = 1;
            for my $check_priority (@all_priorities) {
                if (not grep { $check_priority eq $_ } split ',', $settings{window_priority}) {
                    push @win_priorities, $check_priority;
                }
            }
        }
    }
    $win = $settings{window} if not defined $win;
    if (not &ensure_window($win, '_tw_in_Win')) {
        $win = $settings{window};
    }

    # &debug("window($type, $uname, $sname, $topic) -> $win");
    return $win;
}

sub ensure_window {
    my $win = shift;
    my $using_win = shift;
    return $win if Irssi::window_find_name($win);
    &notice([ 'crap', $using_win ], "Creating window '$win'.");
    my $newwin = Irssi::Windowitem::window_create( $win, 1 );
    if (not $newwin) {
        &notice([ 'error', $using_win ], "Failed to create window $win!");
        return;
    }
    $newwin->set_name($win);
    return $win;
}

sub window_to_account {
    my $name = shift;

    foreach my $type ( keys %{ $state{__windows} } ) {
        foreach my $uname ( keys %{ $state{__windows}{$type} } ) {
            if ( lc $state{__windows}{$type}{$uname} eq lc $name ) {
                return $uname;
            }
        }
    }

    if ( lc $name eq $settings{window} ) {
        return $user;
    }

    return;
}

sub read_json {
    my $file = shift;
    my $store = shift;
    my $desc = shift;
    if ( $file and -r $file ) {
        if ( open( my $fh, '<', $file ) ) {
            my $json;
            do { local $/; $json = <$fh>; };
            close $fh;
            eval {
                my $ref = JSON::Any->jsonToObj($json);
                %$store = %$ref;
            };
        } else {
            &notice( ["error"], "Failed to load $desc from $file: $!" );
        }
    }
}

Irssi::signal_add( "send text",     "event_send_text" );
Irssi::signal_add( "setup changed", "event_setup_changed" );

Irssi::theme_register( # theme
    [
        'twirssi_tweet',       '[$0%B@$1%n$2] $3',
        'twirssi_search',      '[$0%r$1%n%B@$2%n$3] $4',
        'twirssi_search_once', '[$0%r$1%n%B@$2%n$3] $4',
        'twirssi_reply',       '[$0\--> %B@$1%n$2] $3',
        'twirssi_dm',          '[$0%r@$1%n (%WDM%n)] $2',
        'twirssi_error',       '%RERROR%n: $0',
        'twirssi_deerror',     '%RUPDATE%n: $0',
        'twirssi_info',        '%CINFO:%N $0',
        'twirssi_new_day',     '%CDay changed to $0%N',
    ]
);

$last_poll{__poll} = time - &get_poll_time;

&event_setup_changed(1);
if ( Irssi::window_find_name(window()) ) {
    Irssi::command_bind( "dm",                         "cmd_direct" );
    Irssi::command_bind( "dm_as",                      "cmd_direct_as" );
    Irssi::command_bind( "tweet",                      "cmd_tweet" );
    Irssi::command_bind( "tweet_as",                   "cmd_tweet_as" );
    Irssi::command_bind( "retweet",                    "cmd_retweet" );
    Irssi::command_bind( "retweet_as",                 "cmd_retweet_as" );
    Irssi::command_bind( "retweet_to",                 "cmd_retweet_to_window" );
    Irssi::command_bind( "twitter_broadcast",          "cmd_broadcast" );
    Irssi::command_bind( "twitter_info",               "cmd_info" );
    Irssi::command_bind( "twitter_user",               "cmd_user" );
    Irssi::command_bind( "twitter_reply",              "cmd_reply" );
    Irssi::command_bind( "twitter_reply_as",           "cmd_reply_as" );
    Irssi::command_bind( "twitter_login",              "cmd_login" );
    Irssi::command_bind( "twitter_logout",             "cmd_logout" );
    Irssi::command_bind( "twitter_search",             "cmd_search" );
    Irssi::command_bind( "twitter_listinfo",           "cmd_listinfo" );
    Irssi::command_bind( "twitter_dms",                "cmd_dms" );
    Irssi::command_bind( "twitter_dms_as",             "cmd_dms_as" );
    Irssi::command_bind( "twitter_switch",             "cmd_switch" );
    Irssi::command_bind( "twitter_subscribe",          "cmd_add_search" );
    Irssi::command_bind( "twitter_unsubscribe",        "cmd_del_search" );
    Irssi::command_bind( "twitter_list_subscriptions", "cmd_list_search" );
    Irssi::command_bind( "twirssi_upgrade",            "cmd_upgrade" );
    Irssi::command_bind( "twirssi_reload",             "cmd_reload" );
    Irssi::command_bind( "twirssi_oauth",              "cmd_oauth" );
    Irssi::command_bind( "twitter_updates",            "get_updates" );
    Irssi::command_bind( "twitter_add_follow_extra",   "cmd_add_follow" );
    Irssi::command_bind( "twitter_del_follow_extra",   "cmd_del_follow" );
    Irssi::command_bind( "twitter_list_follow_extra",  "cmd_list_follow" );
    Irssi::command_bind( "twirssi_set_channel",        "cmd_set_channel" );
    Irssi::command_bind( "twirssi_list_channels",      "cmd_list_channels" );
    Irssi::command_bind( "twirssi_set_window",         "cmd_set_window" );
    Irssi::command_bind( "twirssi_list_windows",       "cmd_list_windows" );
    Irssi::command_bind( "twirssi_wipe",               "cmd_wipe" );
    Irssi::command_bind( "bitlbee_away",               "update_away" );
    if ( $settings{use_reply_aliases} ) {
        Irssi::command_bind( "reply",    "cmd_reply" );
        Irssi::command_bind( "reply_as", "cmd_reply_as" );
    }
    Irssi::command_bind(
        "twirssi_dump",
        sub {
            &debug( "twits: ", join ", ",
              map { "u: $_\@" . ref($twits{$_}) } keys %twits );
            &debug( "selected: $user\@$defservice" );
            &debug( "friends: ", Dumper \%friends );
            &debug( "blocks: ", Dumper \%blocks );
            &debug( "nicks: ",   join ", ", sort keys %nicks );
            &debug( "searches: ", join(';  ', map { $state{__last_id}{$_}{__search} and "$_ : " . join(', ', keys %{ $state{__last_id}{$_}{__search} }) } keys %{ $state{__last_id} } ));
            &debug( "windows: ",  Dumper \%{ $state{__windows} } );
            &debug( "channels: ",  Dumper \%{ $state{__channels} } );
            &debug( "lists: ", Dumper \%{ $state{__lists} } );
            &debug( "settings: ",  Dumper \%settings );
            &debug( "last poll: ", Dumper \%last_poll );
            if ( open my $fh, '>', "/tmp/$IRSSI{name}.cache.txt" ) {
                print $fh Dumper \%tweet_cache;
                close $fh;
                &notice([ 'crap' ], "cache written out to /tmp/$IRSSI{name}.cache.txt");
            }
            if ( open my $fh, '>', "$settings{dump_store}" ) {
                print $fh Dumper \%state;
                close $fh;
                &notice([ 'crap' ], "state written out to $settings{dump_store}");
            }
        }
    );
    Irssi::command_bind(
        "twirssi_version",
        sub {
            &notice(
                # ["error"],
                "$IRSSI{name} v$VERSION; "
                  . (
                    $Net::Twitter::VERSION
                    ? "Net::Twitter v$Net::Twitter::VERSION. "
                    : ""
                  )
                  . (
                    $Net::Identica::VERSION
                    ? "Net::Identica v$Net::Identica::VERSION. "
                    : ""
                  )
                  . "JSON in use: "
                  . JSON::Any::handler()
                  . ".  See details at http://twirssi.com/"
            );
        }
    );
    Irssi::command_bind(
        "twitter_delete",
        &gen_cmd(
            "/twitter_delete <username:id>",
            "destroy_status",
            sub { &notice( ["tweet"], "Tweet deleted." ); },
            sub {
                my ( $nick, $num ) = split /:/, lc $_[0], 2;
                return $state{__last_id}{ &normalize_username($nick) }{__sent} unless defined $num;
                return $state{__ids}{$nick}[$num];
            }
        )
    );
    Irssi::command_bind(
        "twitter_fav",
        &gen_cmd(
            "/twitter_fav <username:id>",
            "create_favorite",
            sub { &notice( ["tweet"], "Tweet favorited." ); },
            sub {
                my ( $nick, $num ) = split ':', lc $_[0], 2;
                return $state{__last_id}{ &normalize_username($nick) }{__sent} unless defined $num;
                return $state{__ids}{$nick}[$num];
            }
        )
    );
    Irssi::command_bind(
        "twitter_unfav",
        &gen_cmd(
            "/twitter_unfav <username:id>",
            "destroy_favorite",
            sub { &notice( ["tweet"], "Tweet un-favorited." ); },
            sub {
                my ( $nick, $num ) = split ':', lc $_[0], 2;
                return $state{__last_id}{ &normalize_username($nick) }{__sent} unless defined $num;
                return $state{__ids}{$nick}[$num];
            }
        )
    );
    Irssi::command_bind(
        "twitter_follow",
        &gen_cmd(
            "/twitter_follow [-w] <username>",
            "create_friend",
            sub {
                &notice( ["tweet", "$user\@$defservice"],
                         "Following $_[0]" );
                $nicks{ $_[0] } = time;
                &cmd_user(@_);
            },
            sub {
                &cmd_set_window("sender $_[0] $_[0]", $_[1], $_[2])
                        if $_[0] =~ s/^\s*-w\s+// and $_[0] ne '';
                return $_[0];
            }
        )
    );
    Irssi::command_bind(
        "twitter_unfollow",
        &gen_cmd(
            "/twitter_unfollow <username>",
            "destroy_friend",
            sub {
                &notice( ["tweet"], "Stopped following $_[0]" );
                delete $nicks{ $_[0] };
            }
        )
    );
    Irssi::command_bind(
        "twitter_device_updates",
        &gen_cmd(
            "/twitter_device_updates none|im|sms",
            "update_delivery_device",
            sub { &notice( ["tweet"], "Device updated to $_[0]" ); }
        )
    );
    Irssi::command_bind(
        "twitter_block",
        &gen_cmd(
            "/twitter_block <username>",
            "create_block",
            sub { &notice( ["tweet"], "Blocked $_[0]" ); }
        )
    );
    Irssi::command_bind(
        "twitter_unblock",
        &gen_cmd(
            "/twitter_unblock <username>",
            "destroy_block",
            sub { &notice( ["tweet"], "Unblock $_[0]" ); }
        )
    );
    Irssi::command_bind(
        "twitter_spam",
        &gen_cmd(
            "/twitter_spam <username>",
            "report_spam",
            sub { &notice( ["tweet"], "Reported $_[0] for spam" ); }
        )
    );

    %completion_types = (
        'account' => [
            'twitter_switch',
        ],
        'tweet' => [
            'retweet',
            'retweet_to',
            'twitter_delete',
            'twitter_fav',
            'twitter_info',
            'twitter_reply',
            'twitter_unfav',
        ],
        'nick' => [
            'dm',
            'twitter_block',
            'twitter_add_follow_extra',
            'twitter_del_follow_extra',
            'twitter_follow',
            'twitter_spam',
            'twitter_unblock',
            'twitter_unfollow',
            'twitter_user',
            'twitter_dms',	# here for twitter_dms_as
        ],
        're_nick' => [
            'dm',
            'retweet',
            'tweet',
        ],
    );
    push @{ $completion_types{'tweet'} }, 'reply' if $settings{use_reply_aliases};

    Irssi::signal_add_last( 'complete word' => \&sig_complete );

    &notice(
        "  %Y<%C(%B^%C)%N                   TWIRSSI v%R$VERSION%N",
        "   %C(_(\\%N           http://twirssi.com/ for full docs",
        "    %Y||%C `%N Log in with /twitter_login, send updates with /tweet"
    );

    my $file = $settings{replies_store};
    if ( $file and -r $file ) {
        if ( open( my $fh, '<', $file ) ) {
            my $json;
            do { local $/; $json = <$fh>; };
            close $fh;
            eval {
                my $ref = JSON::Any->jsonToObj($json);
                %state = %$ref;
                # fix legacy vulnerable ids
                for (grep !/^__\w+$/, keys %state) { $state{__ids}{$_} = $state{$_}; delete $state{$_}; }
                # # remove legacy broken searches (without service name)
                # map { /\@/ or delete $state{__searches}{$_} } keys %{$state{__searches}};
                # convert legacy/broken window tags (without @service, or unnormalized)
                for my $type (keys %{$state{__windows}}) {
                    next if $type eq 'search' or $type eq 'sender';
                    for my $tag (keys %{$state{__windows}{$type}}) {
                        next if $tag eq 'default';
                        my $new_tag = &normalize_username($tag);
                        next if -1 == index($new_tag, '@') or $new_tag eq $tag;
                        $state{__windows}{$type}{$new_tag} = $state{__windows}{$type}{$tag};
                        delete $state{__windows}{$type}{$tag};
                    }
                }
                my $num = keys %{ $state{__indexes} };
                &notice( sprintf "Loaded old replies from %d contact%s.",
                    $num, ( $num == 1 ? "" : "s" ) );
                &cmd_list_search;
                &cmd_list_follow;
            };
        } else {
            &notice( ["error"], "Failed to load old replies from $file: $!" );
        }
    }

    &read_json($settings{poll_store}, \%last_poll, "prev. poll times");
    &read_json($settings{id_store}, \%tweet_cache, "cached IDs");

    if ( my $provider = $settings{url_provider} ) {
        &notice("Loading WWW::Shorten::$provider...");
        eval "use WWW::Shorten::$provider;";

        if ($@) {
            &notice(["error"],
                "Failed to load WWW::Shorten::$provider - either clear",
                "short_url_provider or install the CPAN module"
            );
        }
    }

    if ( @{ $settings{usernames} } ) {
        &cmd_login();
        &ensure_updates(15) if keys %twits;
    }

} else {
    Irssi::active_win()
      ->print( "Create a window named "
          . $settings{window}
          . " or change the value of twitter_window.  Then, reload $IRSSI{name}." );
}

# vim: set sts=4 expandtab:
