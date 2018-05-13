package Test2::Tools::HTTP::UA::LWP;

use strict;
use warnings;
use URI;
use parent 'Test2::Tools::HTTP::UA';

# ABSTRACT: LWP user agent wrapper for Test2::Tools::HTTP
# VERSION

sub instrument
{
  my($self) = @_;
  
  my $cb = $self->{request_send_cb} ||= sub {
    my($req, $ua, $h) = @_;
    
    if(my $tester = $self->apps->uri_to_tester($req->uri))
    {
      return $tester->request($req);
    }
    else
    {
      return;
    }
  };
  
  $self->ua->set_my_handler( 'request_send' => $cb );
}

sub request
{
  my($self, $req, %options) = @_;

  if($self->apps->uri_to_app($req->uri) && $req->uri =~ /^\//)
  {
    $req->uri(
      URI->new_abs($req->uri, $self->apps->base_url),
    );
  }

  my $res = $options{follow_redirects}
    ? $self->ua->request($req)
    : $self->ua->simple_request($req);

  if(my $warning = $res->header('Client-Warning'))
  {
    $self->error(
      "connection error: " . ($res->decoded_content || $warning),
      $res,
    );
  }

  $res;
}

1;
