# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# QMPlugin is Copyright (C) 2026 Michael Daum http://michaeldaumconsulting.com
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

package Foswiki::Plugins::QMPlugin::Handler::Rest;

use strict;
use warnings;

use Error qw(:try);
use Foswiki::Func ();
use REST::Client ();
use HTTP::CookieJar::LWP ();
use JSON ();
#use Data::Dump qw(dump);

use constant TRACE => 0; # toggle me

sub handle {
  my ($command, $state) = @_;

  _writeDebug("called handle()");

  my $params = $command->getParams();
  my $id = $params->{_DEFAULT};
  unless ($id) {
    #throw Error::Simple("undefined REST id");
    print STDERR "WARNING: undefined REST id in workflow\n";
    return;;
  }
  _writeDebug("id=$id");

  my $config = $Foswiki::cfg{QMPlugin}{RestConfig}{$id};
  unless (defined $config) {
    #throw Error::Simple("unknown REST config $id");
    print STDERR "WARNING: unknown REST config $id in workflow\n";
    return;
  }

  my $url = $config->{url};
  unless (defined $url && $url =~ /^https?:\/\//) {
    #throw Error::Simple("invald REST config $id ... no url") 
    print STDERR "invald REST config $id ... no url in workflow\n";
    return;
  }

  # build url params
  if (defined $config->{params}) {
    my $urlParams;
    %{$urlParams} = %{$config->{params}};
    foreach my $key (keys %$urlParams) {
      my $val = $params->{$key} // '';
      $urlParams->{$key} =~ s/%val%/$val/g;
    }
    $url .= Foswiki::make_params(%$urlParams);
  }

  _writeDebug("url=$url");

  # build body
  my $body;
  if (defined $config->{body}) {
    if (ref($config->{body})) {
      %{$body} = %{$config->{body}};
      foreach my $key (keys %$body) {
	my $val = $params->{$key} // '';
	$body->{$key} =~ s/%val%/$val/g;
      }
      $body = JSON::encode_json($body);
    } else {
      $body = $config->{body};
      foreach my $key (keys %$params) {
	my $val = $params->{$key} // '';
	$body =~ s/%\Q$key\E%/$val/g;
      }
    }
    _writeDebug("body=$body");
  }

  # build http headers
  my $headers;
  if (defined $config->{headers}) {
    %{$headers} = %{$config->{headers}};
    foreach my $key (keys %$headers) {
      my $val = $params->{$key} // '';
      $headers->{$key} =~ s/%val%/$val/g;
    }
    #_writeDebug("headers=".dump($headers)) if TRACE;
  }

  # set up client
  my $client = REST::Client->new({
    follow => 1,
    timeout => 10,
    useragent => LWP::UserAgent->new(
      cookie_jar => HTTP::CookieJar::LWP->new(),
    ),
  });

  # calle method
  my $method = $config->{method} // "";
  unless ($method =~ /^(GET|PUT|PATCH|POST|DELETE|OPTIONS|HEAD)$/) {
    #throw Error::Simple("unknown REST method in config $id");
    print STDERR "WARNING: unknown REST method in config $id in workflow\n";
    return;
  }

  $client->GET($url, $headers) if $method eq 'GET';
  $client->PUT($url, $body, $headers) if $method eq "PUT";
  $client->PATCH($url, $body, $headers) if $method eq "PATCH";
  $client->POST($url, $body, $headers) if $method eq "POST";
  $client->DELETE($url, $headers) if $method eq "DELETE";
  $client->OPTIONS($url, $headers) if $method eq "OPTIONS";
  $client->HEAD($url, $headers) if $method eq "HEAD";

  # read response
  my $code = $client->responseCode();
  my $content = $client->responseContent();

  _writeDebug("code=$code");
  _writeDebug("response=".$client->responseContent());

  if ($code eq '200') {
    Foswiki::Func::setPreferencesValue($id . "_response", $content);
  } else {
    #throw Error::Simple("HTTP Error($code): $content");
    print STDERR "HTTP Error($code) in workflow: $content\n";
  }

  _writeDebug("done rest");
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::Copy - $_[0]\n";
}

1;
