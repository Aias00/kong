-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local cjson = require "cjson"
local spec_parser = require "kong.plugins.oas-validation.utils.spec_parser"
local validation_utils = require "kong.plugins.oas-validation.utils.validation"
local fixture_path  = require "spec.fixtures.fixture_path"


describe("validation utils spec", function ()
  it("get correct spec table from spec string", function ()
    local spec_str = [[
      {
        "openapi": "3.0.0",
        "info": {
          "title": "Sample API",
          "description": "A Sample OpenAPI Spec",
          "termsOfService": "http://swagger.io/terms/",
          "contact": {
            "email": ""
          },
          "license": {
            "name": "Apache 2.0",
            "url": "http://www.apache.org/licenses/LICENSE-2.0.html"
          },
          "version": "1.0.0"
        },
        "servers": [
          {
            "url": "http://example.com/v1"
          }
        ],
        "paths": {
          "/pets": {
            "get": {
              "summary": "List all pets",
              "operationId": "listPets",
              "tags": [
                "pets"
              ],
              "responses": {
                "200": {
                  "description": "A paged array of pets",
                  "headers": {
                    "x-next": {
                      "description": "A link to the next page of responses",
                      "schema": {
                        "type": "string"
                      }
                    }
                  },
                  "content": {
                    "application/json": {
                      "schema": {
                        "type": "string"
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
        ]]
    local res, err = spec_parser.load_spec(spec_str)
    assert.truthy(res)
    assert.is_nil(err)
  end)

  it("get correct spec table from spec string that contains reference", function ()
    local spec_str = [[
      {
        "openapi": "3.0.3",
        "info": {
          "title": "Swagger Petstore - OpenAPI 3.0",
          "description": "",
          "termsOfService": "http://swagger.io/terms/",
          "contact": {
            "email": "apiteam@swagger.io"
          },
          "license": {
            "name": "Apache 2.0",
            "url": "http://www.apache.org/licenses/LICENSE-2.0.html"
          },
          "version": "1.0.11"
        },
        "externalDocs": {
          "description": "Find out more about Swagger",
          "url": "http://swagger.io"
        },
        "servers": [
          {
            "url": "https://petstore3.swagger.io/api/v3"
          }
        ],
        "paths": {
          "/pet": {
            "put": {
              "summary": "Update an existing pet",
              "description": "Update an existing pet by Id",
              "operationId": "updatePet",
              "requestBody": {
                "description": "Update an existent pet in the store",
                "content": {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/Pet"
                    }
                  },
                  "application/xml": {
                    "schema": {
                      "$ref": "#/components/schemas/Pet"
                    }
                  },
                  "application/x-www-form-urlencoded": {
                    "schema": {
                      "$ref": "#/components/schemas/Pet"
                    }
                  }
                },
                "required": true
              },
              "responses": {
                "200": {
                  "description": "Successful operation",
                  "content": {
                    "application/json": {
                      "schema": {
                        "$ref": "#/components/schemas/Pet"
                      }
                    },
                    "application/xml": {
                      "schema": {
                        "$ref": "#/components/schemas/Pet"
                      }
                    }
                  }
                },
                "400": {
                  "description": "Invalid ID supplied"
                },
                "404": {
                  "description": "Pet not found"
                },
                "405": {
                  "description": "Validation exception"
                }
              }
            }
          }
        },
        "components": {
          "schemas": {
            "Tag": {
              "type": "object",
              "properties": {
                "id": {
                  "type": "integer",
                  "format": "int64"
                },
                "name": {
                  "type": "string"
                }
              },
              "xml": {
                "name": "tag"
              }
            },
            "Pet": {
              "required": [
                "name",
                "photoUrls"
              ],
              "type": "object",
              "properties": {
                "id": {
                  "type": "integer",
                  "format": "int64",
                  "example": 10
                },
                "name": {
                  "type": "string",
                  "example": "doggie"
                },
                "photoUrls": {
                  "type": "array",
                  "xml": {
                    "wrapped": true
                  },
                  "items": {
                    "type": "string",
                    "xml": {
                      "name": "photoUrl"
                    }
                  }
                },
                "tags": {
                  "type": "array",
                  "xml": {
                    "wrapped": true
                  },
                  "items": {
                    "$ref": "#/components/schemas/Tag"
                  }
                },
                "status": {
                  "type": "string",
                  "description": "pet status in the store",
                  "enum": [
                    "available",
                    "pending",
                    "sold"
                  ]
                }
              },
              "xml": {
                "name": "pet"
              }
            }
          }
        }
      }
        ]]

    local res, err = spec_parser.load_spec(spec_str)
    assert.truthy(res)
    assert.is_nil(err)
    assert.is_not_nil(res["components"]["schemas"]["Pet"]["properties"]["tags"]["items"])
    assert.is_not_nil(res["paths"]["/pet"]["put"]["requestBody"]["content"]["application/json"]["schema"]["properties"])
  end)

  it("should return error when spec has recursive reference", function ()
    local spec_str = [[
      {
        "openapi": "3.0.3",
        "info": {
          "title": "Swagger Petstore - OpenAPI 3.0",
          "description": "",
          "termsOfService": "http://swagger.io/terms/",
          "contact": {
            "email": "apiteam@swagger.io"
          },
          "license": {
            "name": "Apache 2.0",
            "url": "http://www.apache.org/licenses/LICENSE-2.0.html"
          },
          "version": "1.0.11"
        },
        "externalDocs": {
          "description": "Find out more about Swagger",
          "url": "http://swagger.io"
        },
        "servers": [
          {
            "url": "https://petstore3.swagger.io/api/v3"
          }
        ],
        "paths": {
          "/pet": {
            "put": {
              "summary": "Update an existing pet",
              "description": "Update an existing pet by Id",
              "operationId": "updatePet",
              "requestBody": {
                "description": "Update an existent pet in the store",
                "content": {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/Pet"
                    }
                  },
                  "application/xml": {
                    "schema": {
                      "$ref": "#/components/schemas/Pet"
                    }
                  },
                  "application/x-www-form-urlencoded": {
                    "schema": {
                      "$ref": "#/components/schemas/Pet"
                    }
                  }
                },
                "required": true
              },
              "responses": {
                "200": {
                  "description": "Successful operation",
                  "content": {
                    "application/json": {
                      "schema": {
                        "$ref": "#/components/schemas/Pet"
                      }
                    },
                    "application/xml": {
                      "schema": {
                        "$ref": "#/components/schemas/Pet"
                      }
                    }
                  }
                },
                "400": {
                  "description": "Invalid ID supplied"
                },
                "404": {
                  "description": "Pet not found"
                },
                "405": {
                  "description": "Validation exception"
                }
              }
            }
          }
        },
        "components": {
          "schemas": {
            "Tag": {
              "type": "object",
              "properties": {
                "id": {
                  "type": "integer",
                  "format": "int64"
                },
                "name": {
                  "type": "string"
                },
                "recursivepet": {
                  "$ref": "#/components/schemas/Tag"
                }
              },
              "xml": {
                "name": "tag"
              }
            },
            "Pet": {
              "required": [
                "name",
                "photoUrls"
              ],
              "type": "object",
              "properties": {
                "id": {
                  "type": "integer",
                  "format": "int64",
                  "example": 10
                },
                "name": {
                  "type": "string",
                  "example": "doggie"
                },
                "photoUrls": {
                  "type": "array",
                  "xml": {
                    "wrapped": true
                  },
                  "items": {
                    "type": "string",
                    "xml": {
                      "name": "photoUrl"
                    }
                  }
                },
                "tags": {
                  "type": "array",
                  "xml": {
                    "wrapped": true
                  },
                  "items": {
                    "$ref": "#/components/schemas/Tag"
                  }
                },
                "status": {
                  "type": "string",
                  "description": "pet status in the store",
                  "enum": [
                    "available",
                    "pending",
                    "sold"
                  ]
                }
              },
              "xml": {
                "name": "pet"
              }
            }
          }
        }
      }
    ]]
    local res, err = spec_parser.load_spec(spec_str)
    assert.is_nil(res)
    assert.same(err, "recursion detected in schema dereferencing")
  end)

  it("can fetch correct path & method spec", function ()
    local spec_str = [[
      openapi: 3.0.3
      info:
        title: Swagger Petstore - OpenAPI 3.0
        description: |-
          This is a sample Pet Store Server based on the OpenAPI 3.0 specification.  You can find out more about
          Swagger at [https://swagger.io](https://swagger.io). In the third iteration of the pet store, we've switched to the design first approach!
          You can now help us improve the API whether it's by making changes to the definition itself or to the code.
          That way, with time, we can improve the API in general, and expose some of the new features in OAS3.

          Some useful links:
          - [The Pet Store repository](https://github.com/swagger-api/swagger-petstore)
          - [The source API definition for the Pet Store](https://github.com/swagger-api/swagger-petstore/blob/master/src/main/resources/openapi.yaml)

        termsOfService: http://swagger.io/terms/
        contact:
          email: apiteam@swagger.io
        license:
          name: Apache 2.0
          url: http://www.apache.org/licenses/LICENSE-2.0.html
        version: 1.0.11
      externalDocs:
        description: Find out more about Swagger
        url: http://swagger.io
      servers:
        - url: https://petstore3.swagger.io/api/v3
      tags:
        - name: pet
          description: Everything about your Pets
          externalDocs:
            description: Find out more
            url: http://swagger.io
        - name: store
          description: Access to Petstore orders
          externalDocs:
            description: Find out more about our store
            url: http://swagger.io
        - name: user
          description: Operations about user
      paths:
        /pet/{petId}:
          get:
            tags:
              - pet
            summary: Find pet by ID
            description: Returns a single pet
            operationId: getPetById
            parameters:
              - name: petId
                in: path
                description: ID of pet to return
                required: true
                schema:
                  type: integer
                  format: int64
            responses:
              '200':
                description: successful operation
                content:
                  application/json:
                    schema:
                      $ref: '#/components/schemas/Pet'
                  application/xml:
                    schema:
                      $ref: '#/components/schemas/Pet'
              '400':
                description: Invalid ID supplied
              '404':
                description: Pet not found
            security:
              - api_key: []
              - petstore_auth:
                  - write:pets
                  - read:pets
          post:
            tags:
              - pet
            summary: Updates a pet in the store with form data
            description: ''
            operationId: updatePetWithForm
            parameters:
              - name: petId
                in: path
                description: ID of pet that needs to be updated
                required: true
                schema:
                  type: integer
                  format: int64
              - name: name
                in: query
                description: Name of pet that needs to be updated
                schema:
                  type: string
              - name: status
                in: query
                description: Status of pet that needs to be updated
                schema:
                  type: string
            responses:
              '405':
                description: Invalid input
            security:
              - petstore_auth:
                  - write:pets
                  - read:pets
          delete:
            tags:
              - pet
            summary: Deletes a pet
            description: delete a pet
            operationId: deletePet
            parameters:
              - name: api_key
                in: header
                description: ''
                required: false
                schema:
                  type: string
              - name: petId
                in: path
                description: Pet id to delete
                required: true
                schema:
                  type: integer
                  format: int64
            responses:
              '400':
                description: Invalid pet value
            security:
              - petstore_auth:
                  - write:pets
                  - read:pets
      components:
        schemas:
          Category:
            type: object
            properties:
              id:
                type: integer
                format: int64
                example: 1
              name:
                type: string
                example: Dogs
            xml:
              name: category
          Tag:
            type: object
            properties:
              id:
                type: integer
                format: int64
              name:
                type: string
            xml:
              name: tag
          Pet:
            required:
              - name
              - photoUrls
            type: object
            properties:
              id:
                type: integer
                format: int64
                example: 10
              name:
                type: string
                example: doggie
              category:
                $ref: '#/components/schemas/Category'
              photoUrls:
                type: array
                xml:
                  wrapped: true
                items:
                  type: string
                  xml:
                    name: photoUrl
              tags:
                type: array
                xml:
                  wrapped: true
                items:
                  $ref: '#/components/schemas/Tag'
              status:
                type: string
                description: pet status in the store
                enum:
                  - available
                  - pending
                  - sold
            xml:
              name: pet
    ]]
    local res, err = spec_parser.load_spec(spec_str)
    assert.is_nil(err)
    local conf = { parsed_spec=res }
    local path_spec = spec_parser.get_spec_from_conf(conf, "/pet/123", "GET")
    local path_spec2 = spec_parser.get_spec_from_conf(conf, "/pet/538434e2-600d-11ed-841e-860b1c27d8fd", "GET")
    local path_spec3 = spec_parser.get_spec_from_conf(conf, "/pet/woof.woof", "GET")
    assert.not_nil(path_spec)
    assert.same(path_spec, path_spec2)
    assert.same(path_spec2, path_spec3)
  end)

  it("can merge parameters correctly when only have path-level parameters", function ()
    local spec_str = [[
      {
        "openapi": "3.0.0",
        "info": {
          "title": "Sample API",
          "description": "A Sample OpenAPI Spec",
          "termsOfService": "http://swagger.io/terms/",
          "contact": {
            "email": ""
          },
          "license": {
            "name": "Apache 2.0",
            "url": "http://www.apache.org/licenses/LICENSE-2.0.html"
          },
          "version": "1.0.0"
        },
        "servers": [
          {
            "url": "http://example.com/v1"
          }
        ],
        "paths": {
          "/pet/{id}": {
            "parameters": [
              {
                "in": "path",
                "name": "id",
                "schema": {
                  "type": "integer"
                },
                "required": "true",
                "description": "The pet ID"
              }
            ],
            "get": {
              "summary": "Get a pet by its id",
              "operationId": "getPet",
              "tags": [
                "pets"
              ],
              "responses": {
                "200": {
                  "description": "A paged array of pets",
                  "headers": {
                    "x-next": {
                      "description": "A link to the next page of responses",
                      "schema": {
                        "type": "string"
                      }
                    }
                  },
                  "content": {
                    "application/json": {
                      "schema": {
                        "type": "string"
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
        ]]
    local res, err = spec_parser.load_spec(spec_str)
    assert.truthy(res, err)
    assert.is_nil(err)
    local conf = { parsed_spec=res }
    local method_spec, _, path_params, err = spec_parser.get_spec_from_conf(conf, "/pet/123", "GET")
    assert.is_nil(err)
    local merged_params = validation_utils.merge_params(path_params, method_spec.parameters)
    assert.same(merged_params, path_params)
  end)

  it("can merge parameters correctly when have both method-level and path-level parameters", function ()
    local spec_str = [[
      {
        "openapi": "3.0.0",
        "info": {
          "title": "Sample API",
          "description": "A Sample OpenAPI Spec",
          "termsOfService": "http://swagger.io/terms/",
          "contact": {
            "email": ""
          },
          "license": {
            "name": "Apache 2.0",
            "url": "http://www.apache.org/licenses/LICENSE-2.0.html"
          },
          "version": "1.0.0"
        },
        "servers": [
          {
            "url": "http://example.com/v1"
          }
        ],
        "paths": {
          "/pet/{id}": {
            "parameters": [
              {
                "in": "path",
                "name": "id",
                "schema": {
                  "type": "integer"
                },
                "required": "true",
                "description": "The pet ID"
              },
              {
                "in": "query",
                "name": "pathparam",
                "schema": {
                  "type": "integer"
                },
                "required": "true",
                "description": "An unique path parameter"
              }
            ],
            "get": {
              "parameters": [
                {
                  "in": "path",
                  "name": "id",
                  "schema": {
                    "type": "integer"
                  },
                  "required": "true",
                  "description": "The pet ID with more comment! Should override the path-level parameter"
                },
                {
                  "in": "query",
                  "name": "id",
                  "schema": {
                    "type": "integer"
                  },
                  "required": "true",
                  "description": "The pet ID in query! Should not override"
                }
              ],
              "summary": "Get a pet by its id",
              "operationId": "getPet",
              "tags": [
                "pets"
              ],
              "responses": {
                "200": {
                  "description": "A paged array of pets",
                  "headers": {
                    "x-next": {
                      "description": "A link to the next page of responses",
                      "schema": {
                        "type": "string"
                      }
                    }
                  },
                  "content": {
                    "application/json": {
                      "schema": {
                        "type": "string"
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
        ]]
    local res, err = spec_parser.load_spec(spec_str)
    assert.truthy(res, err)
    assert.is_nil(err)
    local conf = { parsed_spec=res }
    local method_spec, _, path_params, err = spec_parser.get_spec_from_conf(conf, "/pet/123", "GET")
    assert.is_nil(err)
    local merged_params = validation_utils.merge_params(path_params, method_spec.parameters)
    local expected_result = cjson.decode([[[
      {
        "in": "path",
        "name": "id",
        "schema": {
          "type": "integer"
        },
        "required": "true",
        "description": "The pet ID with more comment! Should override the path-level parameter"
      },
      {
        "in": "query",
        "name": "pathparam",
        "schema": {
          "type": "integer"
        },
        "required": "true",
        "description": "An unique path parameter"
      },
      {
        "in": "query",
        "name": "id",
        "schema": {
          "type": "integer"
        },
        "required": "true",
        "description": "The pet ID in query! Should not override"
      }
    ]
]])
    assert.same(merged_params, expected_result)
  end)

  it("can fetch request body content schema", function ()
    local spec_str = fixture_path.read_fixture("petstore-simple.json")
    local res, err = spec_parser.load_spec(spec_str)
    assert.truthy(res)
    assert.is_nil(err)
    local conf = { parsed_spec=res }
    local method_spec, _, _, _ = spec_parser.get_spec_from_conf(conf, "/pet", "PUT")
    assert.truthy(method_spec)
    local schema, _ = validation_utils.locate_request_body_schema(method_spec, "application/json")
    assert.truthy(schema)

    local schema2, err = validation_utils.locate_request_body_schema(method_spec, "text/plain")
    assert.is_nil(schema2)
    assert.same(err, "no request body schema found for content type 'text/plain'")
  end)

  it("can fetch response body content schema", function ()
    local spec_str = fixture_path.read_fixture("petstore-simple.json")
    local res, err = spec_parser.load_spec(spec_str)
    assert.truthy(res)
    assert.is_nil(err)
    local conf = { parsed_spec=res }
    local method_spec, _, _, _ = spec_parser.get_spec_from_conf(conf, "/pet", "PUT")
    assert.truthy(method_spec)

    local schema, err = validation_utils.locate_response_body_schema("openapi", method_spec, 200, "application/json")
    assert.truthy(schema)
    assert.is_nil(err)

    local schema, err = validation_utils.locate_response_body_schema("openapi", method_spec, 400, "application/json")
    assert.is_nil(schema)
    assert.same(err, "no response body schema found for status code '400' and content type 'application/json'")
  end)
end)
