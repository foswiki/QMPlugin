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

package Foswiki::Plugins::QMPlugin::Handler::Formfield;

use strict;
use warnings;

use Error qw(:try);
use Foswiki::Func ();
use Foswiki::Plugins::QMPlugin();

use constant TRACE => 0; # toggle me

sub handle {
  my ($command, $state) = @_;

  _writeDebug("called handle()");

  my $params = $command->getParams();
  my $web = $state->getWeb();
  my $topic = $params->{topic};
  my $meta;
  my $mustSave = 0;

  if ($topic) {
    ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);
    if ($topic ne $state->getTopic()) {
      ($meta) = Foswiki::Func::readTopic($web, $topic);
      $mustSave = 1;
    }
  } else {
    $topic = $state->getTopic();
    $meta = $state->getMeta();
  }

  _writeDebug("topic=$web.$topic");
  
  throw Error::Simple("Access denied") 
    unless $meta->haveAccess("APPROVE") || $meta->haveAccess("CHANGE");

  my $key = $params->{_DEFAULT} || $params->{name};
  my $val = $state->expandValue($params->{value} // '');

  _writeDebug("setting FIELD '$key' to '$val'");
  $meta->putKeyed('FIELD', {
    name  => $key,
    title => $key,
    value => $val,
  });

  # delete formfield from request
  my $request = Foswiki::Func::getRequestObject();
  $request->delete($key);  

  # SMELL: hack for datetime fields
  $request->delete($key.'_date');  
  $request->delete($key.'_time');  

  $state->getCore->saveMeta($meta) if $mustSave;
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::Formfield - $_[0]\n";
}

1;
