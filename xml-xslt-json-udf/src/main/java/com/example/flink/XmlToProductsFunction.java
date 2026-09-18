package com.example.flink;

import com.example.KafkaXmlToAvroTransformer.Product;
import com.example.KafkaXmlToAvroTransformer.Products;
import com.example.XsltTransform;
import com.fasterxml.jackson.dataformat.xml.XmlMapper;

import org.apache.flink.table.annotation.DataTypeHint;
import org.apache.flink.table.annotation.FunctionHint;
import org.apache.flink.table.functions.FunctionContext;
import org.apache.flink.table.functions.TableFunction;
import org.apache.flink.types.Row;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import javax.xml.transform.Templates;

/**
 * Confluent Cloud Flink SQL table function that runs the same XSLT-then-Jackson
 * conversion as KafkaXmlToAvroTransformer#processRecord, but as a UDF instead of a
 * standalone consumer/producer loop. One input XML "products" document fans out into
 * one output row per <product>, so it must be invoked as a table function, e.g.:
 *
 *   SELECT p.name, p.price, p.category
 *   FROM xml_input_topic
 *   CROSS JOIN LATERAL TABLE(xml_to_products(xml_payload)) AS p(name, price, category);
 */
@FunctionHint(output = @DataTypeHint("ROW<name STRING, price DOUBLE, category STRING>"))
public class XmlToProductsFunction extends TableFunction<Row> {

    private static final Logger LOG = LoggerFactory.getLogger(XmlToProductsFunction.class);
    private static final String XSLT_RESOURCE = "transform.xsl";

    private transient Templates xsltTemplates;
    private transient XmlMapper xmlMapper;

    @Override
    public void open(FunctionContext context) throws Exception {
        xsltTemplates = XsltTransform.compile(XSLT_RESOURCE);
        xmlMapper = new XmlMapper();
    }

    public void eval(String xml) {
        if (xml == null) {
            return;
        }
        try {
            String transformedXml = XsltTransform.apply(xml, xsltTemplates);
            Products products = xmlMapper.readValue(transformedXml, Products.class);
            if (products.products == null) {
                return;
            }
            for (Product product : products.products) {
                collect(Row.of(
                        product.name,
                        product.price == null ? null : product.price.doubleValue(),
                        product.category
                ));
            }
        } catch (Exception e) {
            // Malformed/unparseable input is an external-system boundary issue, not fatal:
            // skip this record, matching KafkaXmlToAvroTransformer#processRecord.
            LOG.warn("Skipping unparseable XML input: {}", e.getMessage());
        }
    }
}
