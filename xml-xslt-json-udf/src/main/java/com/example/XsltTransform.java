package com.example;

import javax.xml.XMLConstants;
import javax.xml.transform.Templates;
import javax.xml.transform.Transformer;
import javax.xml.transform.TransformerFactory;
import javax.xml.transform.stream.StreamResult;
import javax.xml.transform.stream.StreamSource;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.StringReader;
import java.nio.charset.StandardCharsets;

/**
 * XSLT compilation/execution shared by KafkaXmlToAvroTransformer and the Flink
 * XmlToProductsFunction UDF, so the XXE hardening below lives in exactly one place.
 */
public final class XsltTransform {

    private XsltTransform() {
    }

    public static Templates compile(String classpathResourceName) throws Exception {
        try (InputStream in = XsltTransform.class.getClassLoader().getResourceAsStream(classpathResourceName)) {
            if (in == null) {
                throw new IOException("Classpath resource not found: " + classpathResourceName);
            }
            TransformerFactory factory = TransformerFactory.newInstance();
            factory.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true);
            factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "");
            factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_STYLESHEET, "");
            return factory.newTemplates(new StreamSource(in));
        }
    }

    public static String apply(String xml, Templates templates) throws Exception {
        Transformer transformer = templates.newTransformer();
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        transformer.transform(
                new StreamSource(new StringReader(xml)),
                new StreamResult(output)
        );
        return output.toString(StandardCharsets.UTF_8);
    }
}
