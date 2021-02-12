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

package Foswiki::Plugins::QMPlugin::Review;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::Review

a Review is part of a State and records the review in progress

=cut

use warnings;
use strict;
use POSIX;

#use Data::Dump qw(dump);

=begin TML

---++ =ClassProperty= TRACE

boolean toggle to enable debugging of this class

=cut

use constant TRACE => 0; # toggle me

=begin TML

---++ =ClassProperty= PROPS

definition of all mandatory properties of an object of its kind;
node, edge and role classes each refine this list 

=cut

use constant PROPS => qw(
  from
  action
  to
  author
  comment 
  date 
  name
  signOff
);

=begin TML

---++ ClassMethod new($web, $topic, $rev, $meta) -> $state

constructor for a state object

=cut

sub new {
  my $class = shift;
  my $state = shift;
  my $data = shift || [];

  my $this = bless({@_}, $class);

  $this->{_state} = $state;
  $this->{_data} = $data;

  $this->prop("name", "id".$state->{_reviewCounter}++);
  $this->prop("author", Foswiki::Func::getWikiName()) unless $this->prop("author");
  $this->prop("date", time()) unless $this->prop("date");

  #_writeDebug("new review: ".$this->stringify());
  #_writeDebug("data: ".dump($this->{_data}));

  return $this;
}

=begin TML

---++ ObjectMethod finish()

called when this object is destroyed

=cut

sub finish {
  my $this = shift;

  undef $this->{_state};
  undef $this->{_data};
}

=begin TML

---++ ObjectMethod getState() -> $state

get the state this review is part of 

=cut

sub getState {
  my $this = shift;

  return $this->{_state};
}

=begin TML

---++ ObjectMethod store($meta)

store the review object into a QMREVIEW meta data record

=cut

sub store {
  my ($this, $meta) = @_;

  return $meta->putKeyed("QMREVIEW", $this->{_data});
}

=begin TML

---++ ObjectMethod props() -> @props

get a list of all known Review properties

=cut

sub props {
  my $this = shift;

  my %props = ();
  $props{$_} = 1 foreach grep {!/^_/} (keys %{$this->{_data}}, PROPS);

  return keys %props;
}

=begin TML

---++ ObjectMethod prop($key, $val) -> $val

getter/setter for a property of this class

=cut

sub prop {
  my ($this, $key, $val) = @_;
  
  return if $key =~ /^_/;

  if (defined $val) { 
    $this->{_data}{$key} = $val;
  }

  return $this->{_data}{$key};
}

=begin TML

---++ ObjectMethod index() -> $index

get the unique index of this object in a set of same objects part of a state 

=cut

sub index {
  my ($this, $val) = @_;

  return $this->prop("name", $val);
}

=begin TML

---++ ObjectMethod render($format, $params) -> $string

render the properties of this object given the specified format string 
params is a hash reference with default values for properties not defined

=cut

sub render {
  my ($this, $format, $params) = @_;

  return "" unless defined $format;

  my $result = $format;
  my $propRegex = join("|", $this->props);
  $params //= {};

  my $signOff = floor(($this->prop("signOff") || 0)*100);
  my $date = $this->prop("date");
  $result =~ s/\$signOff\b/$signOff/g;
  $result =~ s/\$epoch\b/$date/g; 
  $result =~ s/\$date\b/\$formatTime($date)/g; 
  $result =~ s/\$datetime\b/\$formatDateTime($date)/g; 
  $result =~ s/\$title\b/\$nodeTitle(\$state)/g; # alias
  $result =~ s/\$reviewAction\b/$this->prop("action")/ge;
  $result =~ s/\$reviewFrom\b/$this->prop("from")||''/ge;
  $result =~ s/\$review(State|To)\b/$this->prop("to")||$this->prop("state")/ge;
  $result =~ s/\$($propRegex)\b/my $val = $this->prop($1); $val = $params->{$1} unless defined $val && $val ne ""; $this->expandValue($val)/ge;

  return $result;
}

=begin TML

---++ ObjectMethod expandValue($val) -> $val

expand the given value in the context of a state this object is in

=cut

sub expandValue {
  my ($this, $val) = @_;

  my $state = $this->getState;
  $val = $state->expandValue($val) if $state;

  return $val;
}

=begin TML

---++ ObjectMethod stringify() -> $string

returns a string representation of this object

=cut

sub stringify {
  my $this = shift;

  my @result = ();
  foreach my $key (sort $this->props) {
    push @result, "$key=" . ($this->prop($key)//'undef');
  }

  return join(";", @result);
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::Review - $_[0]\n";
}



1;
