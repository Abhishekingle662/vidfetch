"""Override yt-dlp's broken InstagramUserIE with the private feed API.

Stock InstagramUserIE (_WORKING=False) still scrapes window._sharedData /
GraphQL, which Instagram no longer embeds. With cookies we can:
  1. Resolve username → user id via web/search/topsearch
  2. Page posts via i.instagram.com/api/v1/feed/user/{id}/

Each post is handed back as a URL entry so InstagramIE (and VidFetch's
image patch on Android) downloads videos, photos, and carousels.
"""

from __future__ import annotations

from yt_dlp.extractor.instagram import InstagramIE
from yt_dlp.extractor.instagram import InstagramUserIE as _InstagramUserIE
from yt_dlp.utils import ExtractorError, traverse_obj


class InstagramUserIE(_InstagramUserIE, plugin_name='vidfetch'):
    _WORKING = True
    # Stock uses [^/]+ which swallows ?igsh=… into the username id.
    _VALID_URL = r'https?://(?:www\.)?instagram\.com/(?P<id>[^/?#]{2,})/?(?:$|[?#])'

    def _real_extract(self, url):
        username = self._match_id(url).split('?', 1)[0].split('#', 1)[0]
        if not self._get_cookies('https://www.instagram.com/').get('sessionid'):
            self.raise_login_required(
                'Instagram profile downloads require a logged-in session. '
                'Pass cookies via --cookies / Settings.')

        user_id = self._resolve_user_id(username)

        def entries():
            max_id = None
            page = 0
            while True:
                page += 1
                query = {'count': 12}
                if max_id:
                    query['max_id'] = max_id
                feed = self._download_json(
                    f'{self._API_BASE_URL}/feed/user/{user_id}/',
                    username,
                    f'Downloading feed page {page}',
                    headers=self._api_headers,
                    query=query,
                )
                for item in feed.get('items') or []:
                    code = item.get('code')
                    if not code:
                        continue
                    # /p/ works for feed posts, reels, and carousels.
                    yield self.url_result(
                        f'https://www.instagram.com/p/{code}/',
                        ie=InstagramIE.ie_key(),
                        video_id=code,
                    )
                if not feed.get('more_available'):
                    break
                max_id = feed.get('next_max_id')
                if not max_id:
                    break

        return self.playlist_result(
            entries(), username, f'Posts by {username}')

    def _resolve_user_id(self, username):
        # topsearch avoids the frequently-429 web_profile_info endpoint.
        search = self._download_json(
            'https://www.instagram.com/web/search/topsearch/',
            username,
            'Searching for user',
            fatal=False,
            headers=self._api_headers,
            query={'query': username, 'context': 'blended', 'count': 5},
        ) or {}
        for entry in search.get('users') or []:
            user = entry.get('user') or {}
            if (user.get('username') or '').lower() == username.lower():
                user_id = str(user.get('pk') or user.get('id') or '')
                if user_id:
                    return user_id

        info = self._download_json(
            f'{self._API_BASE_URL}/users/web_profile_info/',
            username,
            'Downloading user info',
            headers=self._api_headers,
            query={'username': username},
        )
        user_id = traverse_obj(info, ('data', 'user', 'id'), expected_type=str)
        if not user_id:
            raise ExtractorError(
                f'Unable to resolve Instagram user id for {username}',
                expected=True)
        return user_id
