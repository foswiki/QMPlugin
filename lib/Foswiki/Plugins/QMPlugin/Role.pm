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

package Foswiki::Plugins::QMPlugin::Role;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::Role

implements a role concept for workflows

=cut

use strict;
use warnings;

use Foswiki::Plugins::QMPlugin::Base();
use Foswiki::Func();

our @ISA = qw( Foswiki::Plugins::QMPlugin::Base );

=begin TML

---++ =ClassProperty= PROPS

definition of all mandatory properties of a class of its kind;
node, edge and role classes each refine this list 

=cut

use constant PROPS => qw( id members description notify );

=begin TML

---++ ClassMethod new() -> $core

constructor for a role object

=cut

sub new {
  my $class = shift;

  my $this = $class->SUPER::new(@_);

  $this->index($this->getNet->{_roleCounter}++);

  return $this;
}

=begin TML

---++ ObjectMethod render($format, $params) -> $string

render this node given the specified format string
params is a hash reference with default values for properties not defined

=cut

sub render {
  my ($this, $format, $params) = @_;

  my $result = $format;
  $result =~ s/\$members(?:\((.*?)\))?\b/join(", ", sort map {$_->prop("wikiName") || $_->prop("id")} $this->getMembers($1))/ge;
  $result =~ s/\$isMember(?:\((.*?)\))?/$this->isMember($1)?1:0/ge;
  $result =~ s/\$emails\b/join(", ", sort $this->getEmails())/ge;
  $result = $this->SUPER::render($result, $params);

  return $result;
}

=begin TML

---++ ObjectMethod isMember($idOrUser) -> $boolean

returns true if =$idOrUser= (default current user) is member of this role

=cut

sub isMember {
  my ($this, $idOrUser) = @_;

  $idOrUser ||= Foswiki::Func::getWikiName();
  my $id = ref($idOrUser) ? $idOrUser->prop("id") : $idOrUser;

  foreach my $user ($this->getMembers()) {

    return 1 if $id eq $user->prop("id") || 
                $id eq $user->prop("wikiName") ||
                $id eq $user->prop("userName");

    next if $id =~ /^$Foswiki::regex{emailAddrRegex}$/;
  }
  
  return 0;
}

=begin TML

---++ ObjectMethod getMembers($expand) -> @members

returns the list of members that have this role assigned

=cut

sub getMembers {
  my ($this, $expand, $seen) = @_;

  $seen //= {};
  $expand //= 1;
  
  return if $seen->{$this->prop("id")};    # prevent infinite recursion
  $seen->{$this->prop("id")} = 1;

  my %members = ();
  my $members = $this->prop("members");

  foreach my $id (split(/\s*,\s*/, $this->expandValue($this->prop("members")))) {
    next if $seen->{$id} || $members{$id};
    next if $id =~ /^(nobody)$/i;

    # role
    my $role = $this->getNet->getRole($id);
    if (defined $role) {
      $members{$_->prop("id")} = $_ foreach $role->getMembers($expand, $seen);
      next;
    }

    # group
    my $group = $this->getCore->getGroup($id);
    if (defined $group) {
      if ($expand) {
        $members{$_->prop("id")} = $_ foreach $group->getMembers();
      } else {
        $members{$group->prop("id")} = $group;
      }
      next;
    }

    # user
    my $user = $this->getCore->getUser($id);
    if (defined $user) {
      $members{$user->prop("id")} = $user;
      next;
    }

    #print STDERR "WARNING: undefined type of member '$id' (not a role, user or group)\n"
  }

  return values %members;
}

=begin TML

---++ ObjectMethod getEmails() -> @emails

returns the list of emails of this role. this is either the list of
users as per "notify" property or of all members otherwise.

=cut

sub getEmails {
  my ($this, $seen) = @_;

  $seen //= {};

  return if $seen->{$this->prop("id")};    # prevent infinite recursion
  $seen->{$this->prop("id")} = 1;

  my %members = ();

  my $notify = $this->expandValue($this->prop("notify"));
  $notify =~ s/^\s+|\s+$//g;
  return if $notify =~ /^(none|nobody)$/i;

  if ($notify) {
    foreach my $id (split(/\s*,\s*/, $notify)) {

      # suppress emails
      next if $seen->{$id} || $members{$id};

      # role
      my $role = $this->getNet->getRole($id);
      if (defined $role) {
        $members{$_->prop("id")} = $_ foreach $role->getMembers(0, $seen);
        next;
      }

      # user
      my $user = $this->getCore->getUser($id);
      if (defined $user) {
        $members{$user->prop("id")} = $user;
        next;
      }

      # group
      my $group = $this->getCore->getGroup($id);
      if (defined $group) {
        $members{$group->prop("id")} = $group;
      }
    }

  } else {
    %members = map {$_->prop("id") => $_} $this->getMembers();
  }

  my %emails = ();
  foreach my $member (values %members) {
    $emails{$_} = 1 foreach $member->getEmails();
  }

  my @emails = sort keys %emails;
  return @emails;
}

1;
