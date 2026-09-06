"""Override yt-dlp's InstagramStoryIE so highlights actually download.

Stock InstagramStoryIE scrapes '"user":' out of the highlight webpage.
Instagram no longer embeds that JSON, so extraction dies with
"This content is unreachable" before the reels API is called.

Highlights do not need that scrape: `feed/reels_media/?reel_ids=highlight:ID`
is enough when a sessionid cookie is present. This plugin also accepts
`/s/<base64>` share links (`highlight:<id>`).
"""

from __future__ import annotations

import base64
import binascii

from yt_dlp.extractor.instagram import InstagramStoryIE as _InstagramStoryIE
from yt_dlp.extractor.instagram import _pk_to_id
from yt_dlp.utils import ExtractorError, filter_dict, traverse_obj


def decode_highlight_share_id(code):
    token = (code or '').split('?', 1)[0].strip()
    if not token:
        return None
    token = token.replace('-', '+').replace('_', '/')
    token += '=' * ((-len(token)) % 4)
    try:
        text = base64.b64decode(token).decode('utf-8')
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None
    if text.startswith('highlight:') and text.split(':', 1)[1].isdigit():
        return text.split(':', 1)[1]
    return None


class InstagramStoryIE(_InstagramStoryIE, plugin_name='vidfetch'):
    _VALID_URL = (
        r'https?://(?:www\.)?instagram\.com/'
        r'(?:stories/(?P<user>[^/?#]+)(?:/(?P<id>\d+))?'
        r'|s/(?P<share>[^/?#]+))'
    )

    def _real_extract(self, url):
        mobj = self._match_valid_url(url)
        username, story_id, share = mobj.group('user', 'id', 'share')

        if share:
            story_id = decode_highlight_share_id(share)
            if not story_id:
                raise ExtractorError(
                    'Unsupported Instagram share link. Open the highlight '
                    'and paste the /stories/highlights/… URL instead.',
                    expected=True)
            username = 'highlights'

        if username == 'highlights' and not story_id:
            raise ExtractorError(
                'Input URL is missing a highlight ID', expected=True)

        if not self._get_cookies('https://www.instagram.com/').get('sessionid'):
            self.raise_login_required(
                'Instagram highlights and stories require a logged-in session. '
                'Pass cookies via --cookies / Settings.')

        display_id = story_id or username
        if username == 'highlights':
            reel_id = f'highlight:{story_id}'
            user_id = None
        else:
            user_id = self._resolve_user_id(username)
            reel_id = user_id

        payload = self._download_json(
            f'{self._API_BASE_URL}/feed/reels_media/',
            display_id,
            'Downloading reel media',
            fatal=False,
            headers=self._api_headers,
            query={'reel_ids': reel_id},
        ) or {}

        reels = payload.get('reels') or {}
        reel = reels.get(reel_id)
        if not reel:
            for key, value in reels.items():
                if str(key) == str(reel_id):
                    reel = value
                    break
        if not reel:
            for item in payload.get('reels_media') or []:
                if str(item.get('id') or '') == str(reel_id):
                    reel = item
                    break
        if not reel:
            self.raise_login_required(
                'Instagram did not return this highlight or story. '
                'Sign in or import cookies in Settings.')

        user_info = reel.get('user') or {}
        if user_id is None:
            user_id = str(user_info.get('pk') or user_info.get('id') or '')
        full_name = user_info.get('full_name')
        story_title = reel.get('title') or f'Story by {username}'

        info_data = []
        for item in reel.get('items') or []:
            item.setdefault('user', {}).update(user_info)
            extracted = self._extract_product(item, get_comments=False)
            entries = (
                extracted.get('entries')
                if extracted.get('_type') == 'playlist'
                else [extracted]
            )
            for entry in entries or []:
                if not entry or not entry.get('formats'):
                    continue
                info_data.append({
                    'uploader': full_name,
                    'uploader_id': user_id,
                    **filter_dict(entry),
                })

        if not info_data:
            raise ExtractorError(
                'No downloadable video in this highlight or story',
                expected=True)

        if (username != 'highlights' and story_id
                and not self._yes_playlist(username, story_id)):
            wanted = _pk_to_id(story_id)
            match = traverse_obj(
                info_data, (lambda _, v: v.get('id') == wanted, any))
            if match:
                return match

        return self.playlist_result(
            info_data, playlist_id=story_id or display_id,
            playlist_title=story_title)

    def _resolve_user_id(self, username):
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
