pipr-ws
=======

Picture provider. Resizes external images and caches them.

Pipr-ws is set up to acept URLs in the form of `http://pipr-ws/<consumer_id>/<action>/(<params>|...)/<url>`

It will download the page where the URL points to, cache the result forever, perform an action on it and cache the result of the action forever.

In addition if a URL that is not an image is used, it will try to pick out what seems to be most likely the main image of the page.

The primary cache location is set by the 'cache_dir' key in the configuration file 'config.yml' and it uses the `<url>` as key

The secondary cache (after resizing or cropping) is defined in the plugin part and uses the full url including the action and params:

````
plugins:
    Thumbnail:
        cache: /tmp/pipr/thumb_cache
        compression: 7
        quality: 50
````

The plugin used to resize is a modified version of Dancer::Plugin::Thumbnail - it uses GD::Image for resizing.

The current configuration is shown together with examples on the root page of the web service.

Example:

````
    example   {
        allowed_targets   [
            [0] "http://www.server.com",
            [1] "files"
        ],
        prefix   "http://www.server.com/",
        sizes    [
            [0] "972x",
            [1] "486x"
        ]
    },
````

Means that at http://pipr-ws/example/ the following sizes are allowed to be used with the /resized/ action. Only images that are hosted on http://www.server.com (and relative url 'files') are allowed (allowed_targets), and if a relative URL is given, it will prepend http://www.server.com to it (prefix)

For environment specific settings, check the files in the 'enviroments' directory.

The plan is to move to a simpler strictly Plack-based service, but the current one works and we need it out.

Usage:

  http://pipr-server/abcn/resized/972x/http://server.com/image.jpg?foo=1&bar=2

Tests:
  prove -lv t

Start server:
  bin/pipr-ws daemon

# Dependencies:
libgd-dev


# TODO
- Add functionality for limiting access. This group can fetch the picture from
  externally, this other group can only get out local cache.
- Add fucntionlaity for hashes and other goodies.
- Adapt for "commercial" release.
- Allow registering an URL upfront so that one does not expose internal details about original URLs
- Add better usage docs
