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

package Foswiki::Plugins::QMPlugin::Group;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::Group

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

definition of all mandatory properties of a group

=cut

use constant PROPS => qw( 
  id
  web
  displayName 
  wikiName
);

=begin TML

---++ ClassMethod new() -> $core

constructor for an group object

=cut

sub new {
  my $class = shift;
  my $id = shift;

  return unless Foswiki::Func::isGroup($id);

  my $this = $class->SUPER::new();
  $this->{id} = $id;

  return $this;
}

=begin TML

---++ ObjectMethod _getPropLazy($key, $val) -> $val

lazy getter for some props

=cut

sub _getPropLazy {
  my ($this, $key) = @_;

  # web
  return $Foswiki::cfg{UsersWebName} if $key eq 'web';

  # wikiName
  if ($key eq 'wikiName') {
    my $web = $this->prop('web');
    my $id = $this->prop('id');

    return $id if Foswiki::Func::topicExists($web, $id);
    return "";
  }

  # displayName
  if ($key eq 'displayName') {
    my $web = $this->prop('web');
    my $wikiName = $this->prop('wikiName');
    
    return Foswiki::Func::getTopicTitle($web, $wikiName) if $web && $wikiName;
    return $this->prop('id');
  }

}

=begin TML

---++ ObjectMethod render($format, $params) -> $string

render this group given the specified format string
params is a hash reference with default values for properties not defined

=cut

sub render {
  my ($this, $format, $params) = @_;

  my $result = $this->SUPER::render($format, $params);
  $result =~ s/\$groupLink\b/$this->getLink()/ge;

  return $result
}

=begin TML

---++ ObjectMethod getLink() -> $string

returns a link representation of this group

=cut

sub getLink {
  my $this = shift;

  my $web = $this->prop("web");
  my $wikiName = $this->prop("wikiName");
  my $displayName = $this->prop("displayName");

  return "<a href='%SCRIPTURLPATH{view}%/$web/$wikiName' class='foswikiGroupField'>$displayName</a>" if $wikiName;
  return "<a href='%SCRIPTURLPATH{view}%/$web/WikiGroups?group=".$this->prop("id")."' class='foswikiGroupField'>$displayName</a>";
}

=begin TML

---++ ObjectMethod getEmails() -> @emails

returns a list of emails of this group 

=cut

sub getEmails {
  my $this = shift;

  return _users->getEmails($this->prop("id"));
}

=begin TML

---++ ObjectMethod getMembers() -> @users

returns all users that are a member of this group

TODO: cache members

=cut

sub getMembers {
  my $this = shift;

  my %members = ();
  my $it = _users->eachGroupMember($this->prop("id"));
  while ($it->hasNext()) {
    my $wikiName = $it->next();
    my $obj = $this->getCore->getUser($wikiName);
    $members{$obj->prop("id")} = $obj if defined $obj;
  }

  return values %members;
}

=begin TML

---++ ObjectMethod hasMember($obj) -> $boolean

returns true if the given user or group object is a member of this group

=cut

sub hasMember {
  my ($this, $obj) = @_;
 
  return _users->isInGroup($obj->prop("id"), $this->prop("id")) ? 1 : 0;
}

1;
