# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# QMPlugin is Copyright (C) 2019-2025 Michael Daum http://michaeldaumconsulting.com
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
#use Data::Dump qw(dump); # disable for production
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
  mailTemplate
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

get the number of signatures required to transition this edge;

This can either be a relative value as a percent value between 0 and 1 if the value is preceeded with a percent sign,
or a value > 1 representing the absolute number of signatures required.

=cut

sub getSignOff {
  my $this = shift;

  my $signOff = $this->prop("signOff");

  $signOff =~ s/^\s+|\s+$//g;
  $signOff = 0 if $signOff eq "";

  if ($signOff =~ /^(.*)%$/) {
    $signOff = $1 / 100;
  }

  return $signOff;
}

=begin TML

---++ ObjectMethod isRelativeSignOff() -> $boolean

returns true of a relative signoff has been specified using a percentage

=cut

sub isRelativeSignOff {
  my $this = shift;

  my $signOff = $this->prop("signOff");
  return $signOff =~ /%\s*$/ ? 1 : 0;
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
      $notify = $this->expandValue($role->prop("notify"));
      unless ($notify =~ /^(none|nobody)$/i) {
        $reviewers{$_->prop("id")} = $_ foreach $role->getMembers();
      }
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
      next;
    }

    #print STDERR "WARNING: undefined type of member '$id' (not a role, user or group)\n"
  }

  return values %reviewers;
}

=begin TML

---++ ObjectMethod getEmails() -> @emails

returns the list of email adressess to notify when this edge is transitioned

=cut

sub getEmails {
  my $this = shift;

  my %emails = ();

  my $notify = $this->expandValue($this->prop("notify"));
  $notify =~ s/^\s+|\s+$//g;
  return if $notify =~ /^(none|nobody)$/i;

  foreach my $id (split(/\s*,\s*/, $this->expandValue($notify))) {

    # role
    my $role = $this->getNet->getRole($id);
    if ($role) {
      $emails{$_} = 1 foreach $role->getEmails();
      next;
    } 

    # user
    my $user = $this->getCore->getUser($id);
    if ($user) {
      $emails{$_} = 1 foreach $user->getEmails();
      next;
    }

    # group
    my $group = $this->getCore->getGroup($id);
    if ($group) {
      $emails{$_} = 1 foreach $group->getEmails();
      next;
    }

    # email
    if ($id =~ /^.*\@.*$/) {
      $emails{$id} = 1;
      next;
    }

    #print STDERR "WARNING: undefined type of member '$id' (not a role, user or group)\n"
  }

  my @emails = sort keys %emails;
  return wantarray ? @emails : scalar(@emails);
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

  return 1 if Foswiki::Func::getContext()->{cronjob};
  return 1 unless defined $user;
  return $this->hasAccess("allowed", $user);
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

  return 0 unless $this->isEnabled($user);

  my $trigger = $this->prop("trigger");
  return 0 unless (defined($trigger) && $trigger ne '');

  $trigger = $this->expandValue($trigger);

  return 0 unless Foswiki::Func::isTrue($trigger, 0);
  return 1;
}

=begin TML

---++ ObjectMethod render($format, $params) -> $string

render this edge given the specified format string

=cut

sub render {
  my ($this, $format, $params) = @_;

  my $result = $format;
  $result =~ s/\$emails\b/join(", ", sort $this->getEmails())/ge;
  $result = $this->SUPER::render($result, $params);

  return $result;
}

=begin TML

---++ ObjectMethod execute($state)

execute all commands of this edge 

=cut

sub execute {
  my ($this, $state) = @_;

  return unless $state;

  my $string = $this->expandValue($this->prop("command"));
  return unless $string;

  while ($string !~ /^\s*$/) {
    $this->writeDebug("parsing command: '$string'");
    my $params = {};
    my $id;

    # parse command
    if ($string =~ s/^\s*([a-z][a-zA-Z0-9]*)(?:\((.*?[^\\])\))?//) {
      $id = $1;
      $params = $2;
      if (defined $params) {
        $params =~ s/\\//g;
        $params = Foswiki::Attrs->new($params);
      }
    } elsif ($string =~ s/^[\s,]+//) {
      # command separator
    } else {
      # parse error
      last;
    }

    # queue command
    #$this->writeDebug("queueCommand($id) params=".dump($params));
    $state->queueCommand($this, $id, $params);
  }

  unless ($string =~ /^\s*$/) {
    print STDERR "ERROR: stuck when parsing edge command '$string' in state ".$state->{id}." of workflow ".$state->prop("workflow")."\n";
  }

}

=begin TML

---++ ObjectMethod asJson($state)

returns a json object representing this edge

=cut

sub asJson {
  my ($this) = @_;

  my $json = {};

  foreach my $key (sort $this->props) {

    if ($key eq 'from') {
      $json->{$key} = $this->fromNode->asJson();
      next;
    } 

    if ($key eq 'to') {
      $json->{$key} = $this->toNode->asJson();
      next;
    } 

    if ($key eq 'dialog') {
      my %params = Foswiki::Func::extractParameters($this->prop($key));
      $json->{$key} = \%params;
      next;
    }
    
    $json->{$key} = $this->renderProp($key);
  }
  
  return $json;
}

1;
