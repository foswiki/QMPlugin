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

package Foswiki::Plugins::QMPlugin::User;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::User

thin wrapper for user information, something the foswiki core does not offer

=cut

use strict;
use warnings;

use Foswiki::Plugins::QMPlugin::Base();
use Foswiki::Func();

our @ISA = qw( Foswiki::Plugins::QMPlugin::Base );

# shortcut
sub _users {
  return $Foswiki::Plugins::SESSION->{users};
}

=begin TML

---++ =ClassProperty= PROPS

definition of all mandatory properties of a user

=cut

use constant PROPS => qw( 
  id
  web
  displayName 
  wikiName
  userName
  type
);

=begin TML

---++ ClassMethod new() -> $core

constructor for an user object

=cut

sub new {
  my $class = shift;
  my $id = shift;

  my $this = $class->SUPER::new();

  if ($id =~ /^$Foswiki::regex{emailAddrRegex}$/) {
    $this->{email} = $this->{id} = $this->{displayName} = $id;
    $this->{type} = 'email';
  } else {
    my $cuid = Foswiki::Func::getCanonicalUserID($id);
    return unless $cuid && _users->userExists($cuid);
    $this->{id} = $cuid;
    $this->{type} = 'user';
  }


  return $this;
}

=begin TML

---++ ObjectMethod _getPropLazy($key, $val) -> $val

lazy getter for some props

=cut

sub _getPropLazy {
  my ($this, $key) = @_;

  return "" if $this->{type} eq 'email';

  # web
  return $Foswiki::cfg{UsersWebName} if $key eq 'web';
  
  # wikiName
  return _users->getWikiName($this->prop("id")) if $key eq 'wikiName';

  # userName
  if ($key eq 'userName') {
    my $wikiName = $this->prop("wikiName");
    return $wikiName ? _users->getLoginName($this->prop("id")) : "";
  }

  # email
  if ($key eq 'email') {
    my $wikiName = $this->prop("wikiName");
    if ($wikiName) {
      my @emails = _users->getEmails($this->prop("id"));
      return $emails[0];
    }

    return "";
  }

  # displayName
  if ($key eq 'displayName') {
    my $web = $this->prop('web');
    my $wikiName = $this->prop('wikiName');
    if ($web && $wikiName) {
      if (Foswiki::Func::topicExists($web, $wikiName)) {
        return Foswiki::Func::getTopicTitle($web, $wikiName);
      } else {
        return $wikiName;
      }
    }
    return "";
  }
}

=begin TML

---++ ObjectMethod render($format, $params) -> $string

render this user given the specified format string
params is a hash reference with default values for properties not defined

=cut

sub render {
  my ($this, $format, $params) = @_;

  my $result = $this->SUPER::render($format, $params);
  $result =~ s/\$userLink\b/$this->getLink()/ge;

  return $result
}

=begin TML

---++ ObjectMethod getLink() -> $string

returns a link representation of this user

=cut

sub getLink {
  my $this = shift;

  my $type = $this->prop("type");
  my $web = $this->prop("web");
  my $wikiName = $this->prop("wikiName");
  my $displayName = $this->prop("displayName");

  return "[[mailto:".$this->prop("email")."][$displayName]]" if $type eq 'email';
  return "[[".$web.".".$wikiName."][$displayName]]" if $type eq 'topic';

  if ($wikiName) {
    return "<a href='%SCRIPTURLPATH{view}%/$web/$wikiName' class='foswikiUserField'>$displayName</a>";
  } else {
    return "<nop>".$displayName;
  }

  return "<span class='foswikiAlert'>".$this->prop("id")."</span>";
}

=begin TML

---++ ObjectMethod isMemberOf($group) -> $boolean

returns true if this user is a member of the given group

=cut

sub isMemberOf {
  my ($this, $group) = @_;
 
  return Foswiki::Func::isGroupMember($group->prop("id"), $this->prop("id")) ? 1 :0;
}

=begin TML

---++ ObjectMethod getEmails() -> @emails

returns the primary email of this user

=cut

sub getEmails {
  my $this = shift;

  my @emails = ();
  push @emails, $this->prop("email");
  return @emails;
}

1;
