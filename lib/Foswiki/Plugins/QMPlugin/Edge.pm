# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# QMPlugin is Copyright (C) 2019-2021 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html

package Foswiki::Plugins::QMPlugin::Edge;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::Edge

implements an Edge in a workflow Net

an edge is a directed connection between two Nodes part of a Net

=cut

use strict;
use warnings;

use Foswiki::Func();
use Foswiki::Plugins::QMPlugin::Base();
our @ISA = qw( Foswiki::Plugins::QMPlugin::Base );

=begin TML

---++ =ClassProperty= PROPS

definition of all mandatory properties of an edge

=cut

use constant PROPS => qw( 
  id 
  from 
  action 
  to
  icon
  title 
  trigger
  enabled
  notify
);

=begin TML

---++ ClassMethod new() -> $core

constructor for an edge object

=cut

sub new {
  my $class = shift;

  my $this = $class->SUPER::new(@_);

  $this->index($this->getNet->{_edgeCounter}++);

  # defaults
  $this->{signOff} = 0 unless defined $this->{signOff} && $this->{signOff} ne '';

  $this->prop("id", $this->prop("from") . '/' . $this->prop("action") . '/' . $this->prop("to"));

  return $this;
}

=begin TML

---++ ObjectMethod fromNode()

get the node on the source end of this edge

=cut

sub fromNode {
  my $this = shift;

  return $this->getNet->getNode($this->{from});
}

=begin TML

---++ ObjectMethod toNode()

get the node on the target end of this edge

=cut

sub toNode {
  my $this = shift;

  return $this->getNet->getNode($this->{to});
}

=begin TML

---++ ObjectMethod getSignOff() -> $float

get the minimum percentage required to transition this edge;
returned values are between 0 and 1

=cut

sub getSignOff {
  my $this = shift;

  my $signOff = $this->prop("signOff");

  $signOff =~ s/^\s+|\s+$//g;
  $signOff = 0 if $signOff eq "";

  if ($signOff =~ /^(.*)%$/) {
    $signOff = $1 / 100;
  } else {
    $signOff /= 100 if $signOff > 1;
  }

  return $signOff;
}

=begin TML

---++ ObjectMethod getReviewers() -> @reviewers

returns a list of users that may switch this edge

TODO: cache reviewers

=cut

sub getReviewers {
  my $this = shift;

  my %reviewers = ();

  my $allowed = $this->expandValue($this->prop("allowed"));

  foreach my $id (split(/\s*,\s*/, $allowed)) {

    # role
    my $role = $this->getNet->getRole($id);
    if ($role) {
      $reviewers{$_->prop("id")} = $_ foreach $role->getMembers();
      next;
    } 

    # user
    my $user = $this->getCore->getUser($id);
    if (defined $user) {
      $reviewers{$user->prop("id")} = $user;
      next;
    }

    # group
    my $group = $this->getCore->getGroup($id);
    if (defined $group) {
      $reviewers{$group->prop("id")} = $group;
    }
  }

  return values %reviewers;
}

=begin TML

---++ ObjectMethod getNotify() -> @users

returns a list of users that have to be notified

TODO: cache?

=cut

sub getNotify {
  my $this = shift;

  my %reviewers = ();

  my $notify = $this->expandValue($this->prop("notify"));
  $notify =~ s/^\s+|\s+$//g;
  return if $notify =~ /^(none|nobody)$/i;

  foreach my $id (split(/\s*,\s*/, $this->expandValue($this->prop("notify")))) {

    # role
    my $role = $this->getNet->getRole($id);
    if ($role) {
      $reviewers{$_->prop("id")} = $_ foreach $role->getMembers();
      next;
    } 

    # user
    my $user = $this->getCore->getUser($id);
    if ($user) {
      $reviewers{$user->prop("id")} = $user;
      next;
    }

    # group
    my $group = $this->getCore->getGroup($id);
    if ($group) {
      $reviewers{$_->prop("id")} = $_ foreach $group->getMembers();
    }
  }

  return values %reviewers;
}

=begin TML

---++ ObjectMethod getEmails() -> @emails

returns the list of email adressess to notify when this edge is transitioned

=cut

sub getEmails {
  my ($this) = @_;

  my %emails = map {$_->prop("email") => 1} $this->getNotify();
  my @emails = sort keys %emails;

  return @emails;
}

=begin TML

---++ ObjectMethod isEnabled($user) -> $boolean

returns true if this edge is enabled, that is:

   1 the "enabled" attribute of the edge evaluates to true (or is undef) and
   1 user is a member of the "allowed" list


=cut

sub isEnabled {
  my ($this, $user) = @_;

  my $enabled = $this->prop("enabled");

  if (defined($enabled) && $enabled ne '') {
    $enabled = $this->expandValue($enabled);
    return 0 unless Foswiki::Func::isTrue($enabled);
  }

  return defined($user) ? $this->hasAccess("allowed", $user) : 1;
}

=begin TML

---++ ObjectMethod isTriggerable($user) -> $boolean

returns true if this edge is enabled and triggerable, that is:

   1 the edge is enabled
   1 the "trigger" attribute evaluates to true and
   1 user is a member of the "allowed" list

=cut

sub isTriggerable {
  my ($this, $user) = @_;

  return 0 unless $this->isEnabled($user);;

  my $trigger = $this->prop("trigger");
  return 0 unless (defined($trigger) && $trigger ne '');

  $trigger = $this->expandValue($trigger);
  return 0 unless Foswiki::Func::isTrue($trigger, 0);

  return 1;
}

=begin TML

---++ ObjectMethod execute()

execute all commands of this edge 

=cut

sub execute {
  my $this = shift;

  my $string = $this->expandValue($this->prop("command"));
  return unless $string;

  my $state = $this->getNet->getState;
  return unless $state;

  while ($string !~ /^\s*$/) {
    $this->writeDebug("parsing command: $string");
    my $params = {};
    my $id;

    # parse command
    if ($string =~ s/^\s*([a-z][a-zA-Z0-9]*)(?:\((.*?[^\\])\))?//) {
      $id = $1;
      $params = $2;
      if (defined $params) {
        $params =~ s/\\//g;
        $params = new Foswiki::Attrs($params);
      }
    } elsif ($string =~ s/^[\s,]+//) {
      # command separator
    } else {
      # parse error
      last;
    }

    # queue command
    $state->queueCommand($this, $id, $params);
  }

  if ($string ne "") {
    print STDERR "ERROR: stuck when parsing command '$string'\n";
  }

}

1;
