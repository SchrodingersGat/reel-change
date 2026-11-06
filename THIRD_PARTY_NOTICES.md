# Third-party notices

Parts of this app are ported from the official InvenTree mobile app
(https://github.com/inventree/inventree-app), used under the MIT License:

```
MIT License

Copyright (c) 2019 InvenTree

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Ported files:

- `lib/auth/session_store.dart` (verbatim)
- `lib/auth/auth_result.dart` (adapted)
- `lib/auth/allauth_client.dart` (adapted)
- `lib/auth/auth_service.dart` (login flow adapted from `lib/auth/auth_manager.dart` and `lib/api.dart`)
- `test/session_store_test.dart` (tests adapted from `test/auth_test.dart`)
