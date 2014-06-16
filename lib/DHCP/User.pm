# -*- cperl -*- #

=head1 NAME

DHCP::User - User/Record-Related code.

=head1 DESCRIPTION

This module allows the creation/login-testing of users.

Since usernames are record names this module also contains code
for setting the value of a name.

=cut

=head1 AUTHOR

Steve Kemp <steve@steve.org.uk>

=cut

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014 Steve Kemp <steve@steve.org.uk>.

This library is free software. You can modify and or distribute it under
the same terms as Perl itself.

=cut


use strict;
use warnings;

package DHCP::User;

# Our code
use DHCP::Records;
use DHCP::Config;

# Standard modules.
use Digest::SHA;
use Data::UUID::LibUUID;


=begin doc

Constructor.

Save away the redis handle we're given.

=end doc

=cut

sub new
{
    my ( $proto, %supplied ) = (@_);
    my $class = ref($proto) || $proto;

    my $self = {};

    $self->{ 'redis' } = $supplied{ 'redis' } || die "Missing Redis handle";

    bless( $self, $class );
    return $self;

}


=begin doc

Create a new user on the system.

=end doc

=cut

sub createUser
{
    my ( $self, $user, $pass, $mail ) = (@_);

    $user = lc($user);

    my $redis = $self->{ 'redis' } || die "Missing handle";

    #
    #  Now hash the users password with our Salt
    #
    my $sha = Digest::SHA->new();
    $sha->add($DHCP::Config::SALT);
    $sha->add($pass);
    my $hash = $sha->hexdigest();

    # set their login details.
    $redis->set( "DHCP:USER:$user", $hash );

    if ($mail)
    {
        $redis->set( "DHCP:USER:$user:MAIL", $mail );
    }

    # set their token
    my $uid = new_uuid_string();
    $redis->set( "DHCP:USER:$user:TOKEN", $uid );
    $redis->set( "DHCP:TOKEN:$uid",       $user );
}


=begin doc

Delete a user, by username.

=end doc

=cut

sub deleteUser
{
    my ( $self, $user ) = (@_);

    $user = lc($user);

    #
    # Create a helper for removing the old DNS records.
    #
    my $helper = DHCP::Records->new();

    #
    #  Get all the zones records - so we can see if there are any present
    # for the user we're going to delete.
    #
    my $existing = $helper->getRecords();

    #
    #  If there are records then delete them.
    #
    foreach my $type (qw! A AAAA !)
    {

        #
        #  Look for the old value of the zone.
        #
        my $old_ip = $existing->{ $type }{ $user } || undef;

        if ($old_ip)
        {
            $helper->removeRecord( $user, $type, $old_ip );
        }
    }


    my $redis = $self->{ 'redis' } || die "Missing handle";

    # Get their token so we can remove it.
    my $token = $redis->get("DHCP:USER:$user:TOKEN");

    # Remove the keys.
    $redis->del("DHCP:USER:$user");
    $redis->del("DHCP:USER:$user:MAIL");
    $redis->del("DHCP:USER:$user:TOKEN");
    $redis->del("DHCP:TOKEN:$token");
}


=begin doc

Discover which username (read DNS record) the given token represents.

=end doc

=cut

sub getUserFromToken
{
    my ( $self, $token ) = (@_);

    my $redis = $self->{ 'redis' } || die "Missing handle";
    return ( $redis->get("DHCP:TOKEN:$token") );
}



=begin doc

Set the value of a record to the given IP.

This invokes the Amazon Route53 API to do the necessary.  It is an uglier
method than I'd like.

=end doc

=cut

sub setRecord
{
    my ( $self, $record, $ip ) = (@_);

    #
    # Create a helper
    #
    my $helper = DHCP::Records->new();

    #
    #  Get the existing records - we need to see if the record
    # we're setting a new value to an existing record, or creating a new one.
    #
    my $existing = $helper->getRecords();

    #
    #  The type of the record we're dealing with.
    #
    my $type = 'A';
    $type = 'AAAA' if ( $ip =~ /:/ );

    #
    #  Look for the old value of the zone being updated.
    #
    #  Amazon won't let you say "set foo.example.com = 1.2.3.4",
    # if the `foo` record exists you must delete it, and then recreate it.
    #
    #  Annoyingly deleting without the correct/current value will fail,
    # so you need to search the existing zone to find the old IP.
    #
    my $old_ip = $existing->{ $type }{ $record } || undef;



    #
    #  If we got the old IP then we have to apply a "delete" + "create"
    # pair of events.
    #
    if ($old_ip)
    {
        $helper->removeRecord( $record, $type, $old_ip );
    }

    $helper->createRecord( $record, $type, $ip );

}




=begin doc

Get the token belonging to the given user.

=end doc

=cut

sub getToken
{
    my ( $self, $user ) = (@_);

    my $redis = $self->{ 'redis' } || die "Missing handle";
    return ( $redis->get("DHCP:USER:$user:TOKEN") );
}


=begin doc

Test a login.

=end doc

=cut

sub testLogin
{
    my ( $self, $user, $pass ) = (@_);

    my $redis = $self->{ 'redis' } || die "Missing handle";

    #
    #  Does the user exist?
    #
    return undef unless ( $self->present($user) );

    #
    #  Get the password in the database.
    #
    my $epass = $redis->get("DHCP:USER:$user");

    #
    #  Now hash the users password with our Salt
    #
    my $sha = Digest::SHA->new();
    $sha->add($DHCP::Config::SALT);
    $sha->add($pass);
    my $hash = $sha->hexdigest();

    #
    #  If the computed hash matches the expected hash we're good.
    #
    return $user if ( $hash eq $epass );

    #
    #  Fail.
    #
    return undef;

}


=begin doc

Is the given username already present?

=end doc

=cut

sub present
{
    my ( $self, $user ) = (@_);

    my $redis = $self->{ 'redis' };
    return 1 if ( defined( $redis->get("DHCP:USER:$user") ) );
    return 0;

}

=begin doc

Is the given username forbidden?

=end doc

=cut

sub forbidden
{
    my ( $self, $user ) = (@_);

    # Missing username?  Invalid.
    return 1 if ( !defined($user) || !length($user) );

    # Containing invalid characters?  Invalid.
    return 1 unless ( $user =~ /^([a-z0-9]+)$/i );

    $user = lc($user);

    foreach my $denied (@DHCP::Config::FORBIDDEN)
    {
        return 1 if ( $denied eq $user );
    }

    return 0;
}


1;
