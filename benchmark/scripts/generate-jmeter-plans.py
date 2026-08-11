#!/usr/bin/env python3
"""Generate the versioned Apache JMeter plans used by the thesis benchmark."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from xml.sax.saxutils import escape


ROOT = Path(__file__).resolve().parents[1]
PLAN_DIRECTORY = ROOT / "jmeter"

POST_BODY = '{"items":[{"product_id":1,"quantity":1},{"product_id":2,"quantity":2}]}'

SCENARIOS = {
    "products": {
        "filename": "tcc-products-v1.jmx",
        "label": "GET products",
        "method": "GET",
        "path": "/api/v1/products",
        "status": "200",
        "assertion": """
def require = { condition, message ->
    if (!condition) {
        throw new AssertionError(message)
    }
}

try {
    def root = new groovy.json.JsonSlurper().parseText(prev.getResponseDataAsString())
    require(root instanceof Map, 'response root must be an object')
    require(root.data instanceof List, 'data must be an array')
    require(root.data.size() == 10, 'default product page must contain 10 rows')
    require(root.links instanceof Map, 'links must be an object')
    require(root.meta instanceof Map, 'meta must be an object')
    require(root.meta.total.toString() == '1000', 'product total must be 1000')
    require(root.data.first().id.toString() == '1000', 'first product must be logical product 1000')
    require(root.data.last().id.toString() == '991', 'last product must be logical product 991')
    root.data.each { product ->
        require(product.keySet().containsAll(['id', 'name', 'sku', 'price', 'discount', 'quantity', 'is_active']), 'product contract is incomplete')
    }
} catch (Throwable failure) {
    AssertionResult.setFailure(true)
    AssertionResult.setFailureMessage('products semantic assertion: ' + failure.getMessage())
}
""",
    },
    "orders": {
        "filename": "tcc-orders-v1.jmx",
        "label": "GET orders",
        "method": "GET",
        "path": "/api/v1/orders",
        "status": "200",
        "assertion": """
def require = { condition, message ->
    if (!condition) {
        throw new AssertionError(message)
    }
}

try {
    def root = new groovy.json.JsonSlurper().parseText(prev.getResponseDataAsString())
    require(root instanceof Map, 'response root must be an object')
    require(root.data instanceof List, 'data must be an array')
    require(root.data.size() == 10, 'default order page must contain 10 rows')
    require(root.links instanceof Map, 'links must be an object')
    require(root.meta instanceof Map, 'meta must be an object')
    require(root.meta.total.toString() == '50', 'authenticated user order total must be 50')
    root.data.each { order ->
        require(order.user_id.toString() == '1', 'every listed order must belong to logical user 1')
        require(order.keySet().containsAll(['id', 'status', 'total_price']), 'order contract is incomplete')
    }
} catch (Throwable failure) {
    AssertionResult.setFailure(true)
    AssertionResult.setFailureMessage('orders semantic assertion: ' + failure.getMessage())
}
""",
    },
    "order-show": {
        "filename": "tcc-order-show-v1.jmx",
        "label": "GET logical order 1",
        "method": "GET",
        "path": "/api/v1/orders/${__P(tcc.order.id)}",
        "status": "200",
        "assertion": """
def require = { condition, message ->
    if (!condition) {
        throw new AssertionError(message)
    }
}

try {
    def root = new groovy.json.JsonSlurper().parseText(prev.getResponseDataAsString())
    require(root instanceof Map, 'response root must be an object')
    require(root.data instanceof Map, 'data must be an object')
    require(root.data.id.toString() == props.getProperty('tcc.order.id'), 'physical order ID must match logical-order-1 mapping')
    require(root.data.user_id.toString() == '1', 'order must belong to logical user 1')
    require(root.data.status == 'pending', 'logical order 1 status must be pending')
    require(root.data.total_price.toString() == '120.50', 'logical order 1 total must be 120.50')
    require(root.data.items instanceof List && root.data.items.size() == 2, 'logical order 1 must have two items')
    require(root.data.items[0].product_id.toString() == '1' && root.data.items[0].quantity.toString() == '1', 'first item must be product 1 quantity 1')
    require(root.data.items[1].product_id.toString() == '38' && root.data.items[1].quantity.toString() == '2', 'second item must be product 38 quantity 2')
} catch (Throwable failure) {
    AssertionResult.setFailure(true)
    AssertionResult.setFailureMessage('order-show semantic assertion: ' + failure.getMessage())
}
""",
    },
    "order-create": {
        "filename": "tcc-order-create-v1.jmx",
        "label": "POST order",
        "method": "POST",
        "path": "/api/v1/orders",
        "status": "201",
        "body": POST_BODY,
        "assertion": """
def require = { condition, message ->
    if (!condition) {
        throw new AssertionError(message)
    }
}

try {
    def root = new groovy.json.JsonSlurper().parseText(prev.getResponseDataAsString())
    require(root instanceof Map, 'response root must be an object')
    require(root.data instanceof Map, 'data must be an object')
    require(root.data.id != null && !root.data.id.toString().isBlank(), 'created order ID must be present')
    require(root.data.user_id.toString() == '1', 'created order must belong to logical user 1')
    require(root.data.status == 'pending', 'created order status must be pending')
    require(root.data.total_price.toString() == '31.50', 'created order total must be 31.50')
    require(root.data.items instanceof List && root.data.items.size() == 2, 'created order must have two items')
    require(root.data.items[0].product_id.toString() == '1' && root.data.items[0].quantity.toString() == '1', 'first item must be product 1 quantity 1')
    require(root.data.items[1].product_id.toString() == '2' && root.data.items[1].quantity.toString() == '2', 'second item must be product 2 quantity 2')
} catch (Throwable failure) {
    AssertionResult.setFailure(true)
    AssertionResult.setFailureMessage('order-create semantic assertion: ' + failure.getMessage())
}
""",
    },
}


def property_element(name: str, value: str) -> str:
    return (
        f'<elementProp name="{escape(name)}" elementType="Header">'
        f'<stringProp name="Header.name">{escape(name)}</stringProp>'
        f'<stringProp name="Header.value">{escape(value)}</stringProp>'
        '</elementProp>'
    )


def request_arguments(body: str | None) -> str:
    if body is None:
        return """<elementProp name="HTTPsampler.Arguments" elementType="Arguments" guiclass="HTTPArgumentsPanel" testclass="Arguments" testname="Arguments">
          <collectionProp name="Arguments.arguments"/>
        </elementProp>"""

    return f"""<elementProp name="HTTPsampler.Arguments" elementType="Arguments" guiclass="HTTPArgumentsPanel" testclass="Arguments" testname="Arguments">
          <collectionProp name="Arguments.arguments">
            <elementProp name="" elementType="HTTPArgument">
              <boolProp name="HTTPArgument.always_encode">false</boolProp>
              <stringProp name="Argument.value">{escape(body)}</stringProp>
              <stringProp name="Argument.metadata">=</stringProp>
            </elementProp>
          </collectionProp>
        </elementProp>"""


def idempotency_preprocessor() -> str:
    script = """
int threadNumber = ctx.getThreadNum() + 1
String counterVariable = 'tcc_request_counter'
long counter

if (vars.get(counterVariable) == null) {
    counter = props.getProperty('tcc.counter.' + threadNumber, '0').toLong()
} else {
    counter = vars.get(counterVariable).toLong()
}

counter++
vars.put(counterVariable, counter.toString())
vars.put('tcc_idempotency_key', 'tcc-c' + props.getProperty('threads') + '-r' + props.getProperty('repetition') + '-t' + threadNumber + '-n' + counter)
"""
    return f"""<JSR223PreProcessor guiclass="TestBeanGUI" testclass="JSR223PreProcessor" testname="Deterministic idempotency key" enabled="true">
          <stringProp name="cacheKey">tcc-order-create-idempotency-v1</stringProp>
          <stringProp name="filename"></stringProp>
          <stringProp name="parameters"></stringProp>
          <stringProp name="script">{escape(script.strip())}</stringProp>
          <stringProp name="scriptLanguage">groovy</stringProp>
        </JSR223PreProcessor>
        <hashTree/>"""


def build_plan(name: str, config: dict[str, str]) -> str:
    is_post = config["method"] == "POST"
    headers = [
        property_element("Accept", "application/json"),
        property_element("${__P(tcc.auth.header.name)}", "${__P(tcc.auth.header.value)}"),
    ]
    if is_post:
        headers.extend(
            [
                property_element("Content-Type", "application/json"),
                property_element("Idempotency-Key", "${tcc_idempotency_key}"),
                property_element("X-CSRF-TOKEN", "${__P(tcc.csrf.token,)}"),
            ]
        )

    preprocessor = idempotency_preprocessor() if is_post else ""
    body = config.get("body")
    assertion_script = escape(config["assertion"].strip())

    return f"""<?xml version="1.0" encoding="UTF-8"?>
<jmeterTestPlan version="1.2" properties="5.0" jmeter="5.6.3">
  <hashTree>
    <TestPlan guiclass="TestPlanGui" testclass="TestPlan" testname="TCC {escape(config['label'])} v1" enabled="true">
      <stringProp name="TestPlan.comments">Version 1 frozen thesis plan. HTTP/1.1, keep-alive, no TLS, no load-generator retry.</stringProp>
      <boolProp name="TestPlan.functional_mode">false</boolProp>
      <boolProp name="TestPlan.serialize_threadgroups">false</boolProp>
      <elementProp name="TestPlan.user_defined_variables" elementType="Arguments" guiclass="ArgumentsPanel" testclass="Arguments" testname="User Defined Variables">
        <collectionProp name="Arguments.arguments"/>
      </elementProp>
      <stringProp name="TestPlan.user_define_classpath"></stringProp>
    </TestPlan>
    <hashTree>
      <ThreadGroup guiclass="ThreadGroupGui" testclass="ThreadGroup" testname="TCC {escape(name)}" enabled="true">
        <stringProp name="ThreadGroup.on_sample_error">continue</stringProp>
        <elementProp name="ThreadGroup.main_controller" elementType="LoopController" guiclass="LoopControlPanel" testclass="LoopController" testname="Loop Controller">
          <boolProp name="LoopController.continue_forever">false</boolProp>
          <stringProp name="LoopController.loops">-1</stringProp>
        </elementProp>
        <stringProp name="ThreadGroup.num_threads">${{__P(threads,10)}}</stringProp>
        <stringProp name="ThreadGroup.ramp_time">0</stringProp>
        <boolProp name="ThreadGroup.scheduler">true</boolProp>
        <stringProp name="ThreadGroup.duration">${{__P(duration_seconds,120)}}</stringProp>
        <stringProp name="ThreadGroup.delay">0</stringProp>
        <boolProp name="ThreadGroup.same_user_on_next_iteration">true</boolProp>
      </ThreadGroup>
      <hashTree>
        <HeaderManager guiclass="HeaderPanel" testclass="HeaderManager" testname="Frozen request headers" enabled="true">
          <collectionProp name="HeaderManager.headers">{''.join(headers)}</collectionProp>
        </HeaderManager>
        <hashTree/>
        <HTTPSamplerProxy guiclass="HttpTestSampleGui" testclass="HTTPSamplerProxy" testname="{escape(config['label'])}" enabled="true">
          {request_arguments(body)}
          <stringProp name="HTTPSampler.domain">${{__P(target_host,localhost)}}</stringProp>
          <stringProp name="HTTPSampler.port">${{__P(target_port)}}</stringProp>
          <stringProp name="HTTPSampler.protocol">http</stringProp>
          <stringProp name="HTTPSampler.contentEncoding">UTF-8</stringProp>
          <stringProp name="HTTPSampler.path">{escape(config['path'])}</stringProp>
          <stringProp name="HTTPSampler.method">{config['method']}</stringProp>
          <boolProp name="HTTPSampler.follow_redirects">false</boolProp>
          <boolProp name="HTTPSampler.auto_redirects">false</boolProp>
          <boolProp name="HTTPSampler.use_keepalive">true</boolProp>
          <boolProp name="HTTPSampler.DO_MULTIPART_POST">false</boolProp>
          <boolProp name="HTTPSampler.postBodyRaw">{'true' if is_post else 'false'}</boolProp>
          <stringProp name="HTTPSampler.embedded_url_re"></stringProp>
          <stringProp name="HTTPSampler.connect_timeout">5000</stringProp>
          <stringProp name="HTTPSampler.response_timeout">30000</stringProp>
          <stringProp name="HTTPSampler.implementation">HttpClient4</stringProp>
        </HTTPSamplerProxy>
        <hashTree>
          {preprocessor}
          <ResponseAssertion guiclass="AssertionGui" testclass="ResponseAssertion" testname="HTTP {config['status']}" enabled="true">
            <collectionProp name="Asserion.test_strings">
              <stringProp name="required-status">{config['status']}</stringProp>
            </collectionProp>
            <stringProp name="Assertion.custom_message">Expected HTTP {config['status']}</stringProp>
            <stringProp name="Assertion.test_field">Assertion.response_code</stringProp>
            <boolProp name="Assertion.assume_success">false</boolProp>
            <intProp name="Assertion.test_type">8</intProp>
          </ResponseAssertion>
          <hashTree/>
          <JSR223Assertion guiclass="TestBeanGUI" testclass="JSR223Assertion" testname="Semantic JSON contract" enabled="true">
            <stringProp name="cacheKey">tcc-{name}-semantic-v1</stringProp>
            <stringProp name="filename"></stringProp>
            <stringProp name="parameters"></stringProp>
            <stringProp name="script">{assertion_script}</stringProp>
            <stringProp name="scriptLanguage">groovy</stringProp>
          </JSR223Assertion>
          <hashTree/>
        </hashTree>
      </hashTree>
    </hashTree>
  </hashTree>
</jmeterTestPlan>
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if committed plans differ from generated plans")
    args = parser.parse_args()

    mismatches: list[Path] = []
    for name, config in SCENARIOS.items():
        path = PLAN_DIRECTORY / config["filename"]
        generated = build_plan(name, config)

        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != generated:
                mismatches.append(path)
        else:
            path.write_text(generated, encoding="utf-8")

    if mismatches:
        for path in mismatches:
            print(f"out-of-date JMeter plan: {path}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
