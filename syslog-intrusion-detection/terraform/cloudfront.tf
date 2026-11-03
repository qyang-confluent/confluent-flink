# HTTPS front door: Confluent Cloud Flink only accepts https:// endpoints; CloudFront gives a trusted cert with no domain.
data "aws_cloudfront_cache_policy" "caching_disabled" {
  count = local.vllm ? 1 : 0
  name  = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  count = local.vllm ? 1 : 0
  name  = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "slm" {
  count           = local.vllm ? 1 : 0
  enabled         = true
  comment         = "syslog SLM endpoint"
  price_class     = "PriceClass_100"
  is_ipv6_enabled = true

  origin {
    origin_id   = "slm-ec2"
    domain_name = aws_instance.slm[0].public_dns
    custom_origin_config {
      http_port                = var.serve_port
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 30
    }
  }

  default_cache_behavior {
    target_origin_id         = "slm-ec2"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

output "serve_https_url" {
  value = local.vllm ? "https://${aws_cloudfront_distribution.slm[0].domain_name}" : null
}
