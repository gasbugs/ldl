"""Regression checks for the idempotent course EC2 recovery contract."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
RESTORE = (ROOT / "tools/restore-course-ec2.sh").read_text()
DELETE = (ROOT / "tools/delete-course-ec2.sh").read_text()


class CourseEc2RecoveryTests(unittest.TestCase):
    def test_module08_preparation_actions_are_granted(self):
        required = {
            "s3:CreateBucket",
            "s3:PutBucketPublicAccessBlock",
            "s3:PutObject",
            "s3vectors:CreateVectorBucket",
            "s3vectors:CreateIndex",
            "iam:CreateRole",
            "iam:PutRolePolicy",
            "iam:UpdateAssumeRolePolicy",
            "iam:PassRole",
            "bedrock:ListKnowledgeBases",
            "bedrock:CreateKnowledgeBase",
            "bedrock:GetKnowledgeBase",
            "bedrock:CreateDataSource",
            "bedrock:StartIngestionJob",
            "bedrock:GetIngestionJob",
            "bedrock:Retrieve",
        }
        for action in required:
            self.assertIn(f'"{action}"', RESTORE)

    def test_permissions_are_scoped_to_module08_resources(self):
        self.assertIn("MODULE08_PREFIX=owasp-llm-module08", RESTORE)
        self.assertIn('"iam:PassedToService": "bedrock.amazonaws.com"', RESTORE)
        self.assertIn('"aws:RequestTag/Project": "llm-defense-lab"', RESTORE)
        self.assertIn('"aws:RequestTag/Module": "08"', RESTORE)

    def test_existing_key_and_instance_are_preserved(self):
        self.assertIn("describe-key-pairs --key-names", RESTORE)
        self.assertIn("describe-instances", RESTORE)
        self.assertNotIn("delete-key-pair", RESTORE)
        self.assertNotIn("terminate-instances", RESTORE)

    def test_existing_instance_profile_is_not_replaced(self):
        self.assertIn("associate-iam-instance-profile", RESTORE)
        self.assertNotIn("replace-iam-instance-profile-association", RESTORE)
        self.assertIn("preserving the current profile; no replacement was attempted", RESTORE)

    def test_cleanup_knows_the_new_inline_policy(self):
        self.assertIn("OwaspLabKnowledgePreparation", DELETE)


if __name__ == "__main__":
    unittest.main()
