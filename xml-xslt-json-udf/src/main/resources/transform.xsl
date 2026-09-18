<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0"
                xmlns:xsl="http://www.w3.org/1999/XSL/Transform">

    <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
    <xsl:strip-space elements="*"/>

    <xsl:template match="/">
        <products>
            <xsl:for-each select="products/product">
                <product>
                    <name>
                        <xsl:value-of select="name"/>
                    </name>
                    <price>
                        <xsl:value-of select="price"/>
                    </price>
                    <category>
                        <xsl:choose>
                            <xsl:when test="price &gt;= 1000">
                                <xsl:text>Premium product</xsl:text>
                            </xsl:when>
                            <xsl:when test="price &gt;= 100">
                                <xsl:text>Standard product</xsl:text>
                            </xsl:when>
                            <xsl:otherwise>
                                <xsl:text>Budget product</xsl:text>
                            </xsl:otherwise>
                        </xsl:choose>
                    </category>
                </product>
            </xsl:for-each>
        </products>
    </xsl:template>

</xsl:stylesheet>
