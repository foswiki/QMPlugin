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

package Foswiki::Plugins::QMPlugin::Command;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::Command

implements a command that is executed while traversing a net

=cut

use warnings;
use strict;

=begin TML

---++ =ClassProperty= TRACE

boolean toggle to enable debugging of this class

=cut

use constant TRACE => 0; # toggle me

=begin TML

---++ ClassMethod new($handler, $source, $params) -> $command

constructor for a command object

=cut

sub new {
  my $class = shift;
  my $handler = shift;
  my $source = shift;
  my $params = shift;

  my $this = bless({@_}, $class);

  $this->{_handler} = $handler;
  $this->{_source} = $source;
  $this->{_params} = $params;

  return $this;
}

=begin TML

---++ ObjectMethod getSource()

simple getter

=cut

sub getSource {
  my $this = shift;

  return $this->{_source};
}

=begin TML

---++ ObjectMethod getParams()

simple getter

=cut

sub getParams {
  my $this = shift;

  return $this->{_params};
}

=begin TML

---++ ObjectMethod finish()

=cut

sub finish {
  my $this = shift;

  undef $this->{_handler};
  undef $this->{_source};
  undef $this->{_params};
}

=begin TML

---++ ObjectMethod execute()

handle and destroy

=cut

sub execute {
  my $this = shift;

  $this->handle();
  $this->finish();
}

=begin TML

---++ ObjectMethod handle()

execute the command

=cut

sub handle {
  my $this = shift;

  _writeDebug("handle command $this->{_handler}{id}");
  _writeDebug("calling handler for source ".$this->{_source}->stringify()) if TRACE;

  &{$this->{_handler}{callback}}($this);
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::Command - $_[0]\n";
}

1;
