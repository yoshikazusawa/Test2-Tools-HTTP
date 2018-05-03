package Test2::Tools::HTTP;

use strict;
use warnings;
use 5.008001;
use LWP::UserAgent;
use parent qw( Exporter );
use Test2::API qw( context );
use Test2::Compare;
use Test2::Compare::Wildcard;
use Test2::Tools::Compare ();
use JSON::MaybeXS qw( decode_json );
use JSON::Pointer;
use URI;
use Carp ();

our @EXPORT    = qw( http_request http_ua http_base_url psgi_app_add psgi_app_del http_response http_code http_message http_content http_json http_last http_is_success );
our @EXPORT_OK = (@EXPORT);

# ABSTRACT: Test HTTP / PSGI
# VERSION

=head1 FUNCTIONS

=head2 http_request

 http_request($request, $check, $message);

=cut

my %psgi;
my $last;

sub http_request
{
  my($req, $check, $message) = @_;

  $req = $req->clone;

  my $url = URI->new_abs($req->uri, http_base_url());
  my $key = _uri_key($url);

  $message ||= "@{[ $req->method ]} @{[ $url ]}";

  my $ctx = context();
  my $ok = 1;
  my @diag;
  my $res;
  my $connection_error = 0;

  if(my $tester = $psgi{$key})
  {
    $res = $tester->request($req);
  }
  else
  {
    if($req->uri =~ /^\//)
    {
      $req->uri(
        URI->new_abs($req->uri, http_base_url())->as_string
      );
    }
    $res = http_ua()->simple_request($req);
  }

  if(my $warning = $res->header('Client-Warning'))
  {
    $ok = 0;
    $connection_error = 1;
    push @diag, "connection error: " . ($res->decoded_content || $warning);
  }

  if($ok && defined $check)
  {
    my $delta = Test2::Compare::compare($res, $check, \&Test2::Compare::strict_convert);
    if($delta)
    {
      $ok = 0;
      push @diag, $delta->diag;
    }
  }

  $ctx->ok($ok, $message, \@diag);
  $ctx->release;

  $last = bless { req => $req, res => $res, ok => $ok, connection_error => $connection_error }, 'Test2::Tools::HTTP::Last';
  
  $ok;
}

=head2 http_response

 my $check = http_response {
   ... # object or http checks
 };

=cut

sub http_response (&)
{
  Test2::Compare::build(
    'Test2::Tools::HTTP::ResponseCompare',
    @_,
  );
}

=head2 http_code

=cut

sub _build
{
  defined(my $build = Test2::Compare::get_build()) or Carp::croak "No current build!";
  Carp::croak "'$build' is not a Test2::Tools::HTTP::ResponseCompare"
    unless $build->isa('Test2::Tools::HTTP::ResponseCompare');

  my $i = 1;
  my @caller;
  while(@caller = caller $i)
  {
    last if $caller[0] ne __PACKAGE__;
    $i++;
  }

  my $func_name = $caller[3];
  $func_name =~ s/^.*:://;
  Carp::croak "'$func_name' should only ever be called in void context"
    if defined $caller[5];

  ($build, file => $caller[1], lines => [$caller[2]]);
}

sub _add_call
{
  my($name, $expect, $context) = @_;
  $context ||= 'scalar';
  my($build, @cmpargs) = _build;
  $build->add_call(
    $name,
    Test2::Compare::Wildcard->new(
      expect => $expect,
      @cmpargs,
    ),
    undef,
    $context
  );
}

sub http_code ($)
{
  my($expect) = @_;
  _add_call('code', $expect);
}

=head2 http_message

=cut

sub http_message ($)
{
  my($expect) = @_;
  _add_call('message', $expect);
}

=head2 http_content

=cut

sub http_content ($)
{
  my($expect) = @_;
  _add_call('decoded_content', $expect);
}

=head2 http_json

=cut

sub http_json
{
  my($pointer, $expect) = @_ == 1 ? ('', $_[0]) : (@_);
  my($build, @cmpargs) = _build;
  $build->add_http_check(
    sub {
      my($res) = @_;
      
      my $object = eval {
        decode_json($res->decoded_content)
      };
      if(my $error = $@)
      {
        # this is terrible!
        $error =~ s/ at \S+ line [0-9]+\.//;
        die "error decoding JSON: $error\n";
      }
      (
        JSON::Pointer->get($object, $pointer),
        JSON::Pointer->contains($object, $pointer),
      )
    },
    [DEREF => $pointer eq '' ? 'json' : "json $pointer"],
    Test2::Compare::Wildcard->new(
      expect => $expect,
      @cmpargs,
    ),
  );
}

=head2 http_is_success

=cut

sub http_is_success
{
  my($expect) = @_;
  _add_call('is_success', Test2::Tools::Compare::T());
}

# TODO: is_info, is_success, is_redirect, is_error is_client_error is_server_error
# TODO: content_type, content_type_charset, content_length, content_length_ok, location
# TODO: header $key => $check
# TODO: cookie $key => $check ??

=head2 http_last

=cut

sub http_last
{
  $last;
}

=head2 http_base_url

 http_base_url($url);
 my $url = http_base_url;

=cut

my $base_url;

sub http_base_url
{
  my($new) = @_;

  if($new)
  {
    $base_url = ref $new ? $new : URI->new($new);
  }
  
  unless(defined $base_url)
  {
    $base_url = URI->new('http://localhost/');
    require IO::Socket::INET;
    $base_url->port(IO::Socket::INET->new(Listen => 5, LocalAddr => "127.0.0.1")->sockport);
  }

  $base_url;
}

=head2 http_ua

 http_ua(LWP::UserAgent->new);
 my $ua = http_ua;

=cut

my $ua;

sub http_ua
{
  my($new) = @_;

  $ua = $new if $new;

  unless(defined $ua)
  {
    $ua = LWP::UserAgent->new;
    $ua->env_proxy;
    $ua->cookie_jar({});
  }

  $ua;
}

=head2 psgi_app_add

 psgi_app_add $app;
 psgi_app_add $url, $app;

=cut

sub _uri_key
{
  my($uri) = @_;
  $uri = URI->new($uri) unless ref $uri;
  join ':', map { $uri->$_ } qw( scheme host port );
}

sub psgi_app_add
{
  my($url, $app) = @_ == 1 ? (http_base_url, @_) : (@_);
  require Plack::Test;
  my $key = _uri_key $url;
  $psgi{$key} = Plack::Test->create($app);
  return;
}

=head2 psgi_app_del

 psgi_app_del;
 psgi_app_del $url;

=cut

sub psgi_app_del
{
  my($url) = @_;
  $url ||= http_base_url;
  my $key = _uri_key $url;
  delete $psgi{$key};
  return;
}

package Test2::Tools::HTTP::Last;

sub req { shift->{req} }
sub res { shift->{res} }
sub ok  { shift->{ok}  }
sub connection_error { shift->{connection_error} }

sub _note_or_diag
{
  my($self, $method) = @_;
  my $ctx = Test2::API::context();

  $ctx->$method($self->req->as_string);

  if(length $self->res->content > 200)
  {
    $ctx->$method($self->res->headers->as_string . "[large body removed]");
  }
  else
  {
    $ctx->$method($self->res->as_string);
  }

  $ctx->$method("ok = " . $self->ok);
  
  $ctx->release;
}

sub note
{
  my($self) = shift;
  my $ctx = Test2::API::context();
  $self->_note_or_diag('note');
  $ctx->release;
}

sub diag
{
  my($self) = shift;
  my $ctx = Test2::API::context();
  $self->_note_or_diag('diag');
  $ctx->release;
}

package Test2::Tools::HTTP::ResponseCompare;

use parent 'Test2::Compare::Object';

sub name { '<HTTP::Response>' }
sub object_base { 'HTTP::Response' }

sub init
{
  my($self) = @_;
  $self->{HTTP_CHECK} ||= [];
  $self->SUPER::init();
}

sub add_http_check
{
  my($self, $cb, $id, $expect) = @_;

  push @{ $self->{HTTP_CHECK} }, [ $cb, $id, $expect ];
}

sub deltas
{
  my $self = shift;
  my @deltas = $self->SUPER::deltas(@_);
  my %params = @_;

  my ($got, $convert, $seen) = @params{qw/got convert seen/};

  foreach my $pair (@{ $self->{HTTP_CHECK} })
  {
    my($cb, $id, $check) = @$pair;

    $check = $convert->($check);

    my($val, $exists) = eval { $cb->($got) };
    my $error = $@;

    if($error)
    {
      push @deltas => $self->delta_class->new(
        verified  => undef,
        id        => $id,
        got       => undef,
        check     => $check,
        exception => $error,
      );
    }
    else
    {
      push @deltas => $check->run(
        id      => $id,
        convert => $convert,
        seen    => $seen,
        exists  => $exists,
        $exists ? ( got => $val) : (),
      );
    }
  }

  @deltas;
}

1;
