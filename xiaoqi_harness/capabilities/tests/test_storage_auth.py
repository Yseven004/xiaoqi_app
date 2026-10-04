"""Offline credential-routing regression: python -m unittest capabilities.tests.test_storage_auth."""

import os
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from capabilities.storage import CloudStore


class Auth:
    def __init__(self, access_key_id, access_key_secret):
        self.credentials = (access_key_id, access_key_secret)


class StsAuth:
    def __init__(self, access_key_id, access_key_secret, security_token):
        self.credentials = (access_key_id, access_key_secret, security_token)


class StorageAuthTest(unittest.TestCase):
    def test_credentials_reach_both_storage_clients(self):
        for token in (None, "", "test-session-token"):
            with self.subTest(has_token=bool(token)):
                env = {
                    "OTS_ENDPOINT": "https://example.invalid",
                    "OTS_INSTANCE": "test",
                    "OSS_ENDPOINT": "https://oss-cn-hangzhou.aliyuncs.com",
                    "OSS_BUCKET": "test",
                    "OSS_REGION": "cn-hangzhou",
                    "ALIBABA_CLOUD_ACCESS_KEY_ID": "test-id",
                    "ALIBABA_CLOUD_ACCESS_KEY_SECRET": "test-secret",
                }
                if token is not None:
                    env["ALIBABA_CLOUD_SECURITY_TOKEN"] = token
                oss = SimpleNamespace(
                    Auth=Auth, StsAuth=StsAuth,
                    Bucket=lambda auth, *args, **kwargs: auth,
                )
                ots = SimpleNamespace(OTSClient=lambda *args, **kwargs: kwargs)
                with patch.dict(os.environ, env, clear=True), patch.dict(
                    sys.modules, {"oss2": oss, "tablestore": ots}
                ):
                    store = CloudStore()
                self.assertIs(type(store._bucket), StsAuth if token else Auth)
                expected = ("test-id", "test-secret") + ((token,) if token else ())
                self.assertEqual(store._bucket.credentials, expected)
                self.assertEqual(store._client["sts_token"], token)


if __name__ == "__main__":
    unittest.main()
